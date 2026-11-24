import 'package:flutter_test/flutter_test.dart';
import 'package:netpulse_router_manager/drivers/router_driver.dart';
import 'package:netpulse_router_manager/drivers/zyxel/zyxel_vmg3625_driver.dart';

import 'fake_zyxel_server.dart';

const _pass = '11223344';

void main() {
  for (final (encrypted, https) in [(true, true), (false, true), (true, false)]) {
    group('${encrypted ? 'encrypted' : 'plain'} API over ${https ? 'HTTPS (self-signed)' : 'HTTP'}', () {
      late FakeZyxelServer server;
      late ZyxelVmg3625Driver driver;
      final trace = <String>[];

      setUp(() async {
        server = FakeZyxelServer(encrypted: encrypted, https: https);
        await server.start();
        trace.clear();
        // Saved settings may say HTTP: the driver must find HTTPS by itself.
        driver = ZyxelVmg3625Driver(
          RouterCredentials(gatewayIp: '127.0.0.1:${server.port}', username: 'admin', password: _pass),
          trace: trace.add,
        );
      });

      tearDown(() async {
        driver.dispose();
        await server.stop();
      });

      test('login picks the working scheme and encryption mode', () async {
        await driver.login();
        expect(driver.isLoggedIn, isTrue);
        expect(driver.encrypted, encrypted);
        expect(driver.usingHttps, https);
        expect(driver.adminPageUri.scheme, https ? 'https' : 'http');
      });

      test('status (real cardpage_status layout)', () async {
        final st = await driver.getRouterStatus();
        expect(st.model, 'VMG3625-T50B');
        expect(st.connected, isTrue);
        expect(st.wanIp, '41.235.18.77', reason: 'IPv4Address[] of the internet WAN, not LAN/IPTV');
        expect(st.dslDownstreamKbps, 51200);
        expect(st.uptime, const Duration(seconds: 93784));
        expect(st.wanType, contains('PPPoE'));
      });

      test('traffic counters come from the PPPoE interface', () async {
        final c = await driver.getTrafficCounters();
        expect(c.rxBytes, server.rxBytes);
        expect(c.txBytes, server.txBytes);
      });

      test('rotated sessionkey is used for the next write (was HTTP 403 on reboot)', () async {
        await driver.setDns(DnsSettings.fromPreset(DnsPreset.cloudflare)); // write #1 rotates key
        await driver.setWifiSpeedLimit(SpeedLimit.mbps(6)); // write #2 must use the new key
        await driver.rebootRouter(); // write #3
        expect(server.staleCsrfRejections, 0);
        expect(server.rebootCount, 1);
        expect(server.loginCount, 1, reason: 'no re-login needed when the key is tracked');
      });

      test('a stale key (403) triggers one re-login and the write still succeeds', () async {
        await driver.login();
        // Rotate the key behind the driver's back (e.g. another tab saved something).
        server.expireSessions();
        await driver.rebootRouter();
        expect(server.rebootCount, 1);
        expect(server.loginCount, 2);
      });

      test('speed limit via QoS General downstream bandwidth', () async {
        final r = await driver.setWifiSpeedLimit(SpeedLimit.mbps(6));
        expect(r.success, isTrue, reason: r.message);
        expect(server.qos['Enable'], isTrue);
        expect(server.qos['DownRate'], 6000);
        expect(server.qos['UpRate'], 0, reason: 'upload untouched');
        expect((await driver.getWifiSpeedLimit()).mbps, 6);

        final off = await driver.setWifiSpeedLimit(const SpeedLimit.unlimited());
        expect(off.success, isTrue);
        expect(server.qos['Enable'], isFalse);
        expect((await driver.getWifiSpeedLimit()).isUnlimited, isTrue);
        expect(server.requests.where((r) => r.contains('qos_shaper')), isEmpty,
            reason: 'the shaper rejects non-WAN interfaces on real firmware');
      });

      test('devices: names, band from standard / Layer1Interface, Active as 1/true/false', () async {
        final d = await driver.getConnectedDevices();
        expect(d.map((x) => x.name), ['Galaxy-S25', '00:1B:21:3C:8D:50', 'TV']);
        expect(d.map((x) => x.band), [WifiBand.band5, WifiBand.ethernet, WifiBand.band24]);
        expect(d.map((x) => x.active), [true, true, false]);
      });

      test('devices: 0-5 signal level, per-device bytes (Sent = downloaded)', () async {
        final d = await driver.getConnectedDevices();
        expect(d[0].signalLevel, 4);
        expect(d[0].signalDbm, isNull, reason: 'was wrongly shown as "4 dBm"');
        expect(d[1].signalLevel, isNull, reason: 'wired');
        expect(d[0].downloadedBytes, 5000000000);
        expect(d[0].uploadedBytes, 300000000);
      });

      test('block / unblock a device through a parental-control profile', () async {
        const mac = 'A4:C3:F0:12:9B:01';
        await driver.setDeviceBlocked(mac, true);
        final p = server.parental.singleWhere((e) => e['pcpName'] == ZyxelVmg3625Driver.profileName(mac));
        expect(p['MACAddressList'], mac);
        expect(p['pcpEnable'], 1);
        expect(p['TimeRangeList'], '00:00-23:59');
        expect(p['Days'], 'Mon,Tue,Wed,Thu,Fri,Sat,Sun');
        expect(server.parentalMaster, '1');
        expect((await driver.getConnectedDevices()).first.blocked, isTrue);

        await driver.setDeviceBlocked(mac, true); // idempotent: no duplicate profile
        expect(server.parental.where((e) => e['pcpName'] == ZyxelVmg3625Driver.profileName(mac)), hasLength(1));

        await driver.setDeviceBlocked(mac, false);
        expect(server.parental.map((e) => e['pcpName']), ['Kids-Night'], reason: "user's own profile kept");
        expect((await driver.getConnectedDevices()).first.blocked, isFalse);
        expect(server.staleCsrfRejections, 0);
      });

      test('wifi settings round-trip keeps firmware key names', () async {
        final w = await driver.getWifiSettings();
        expect(w.ssid, 'WE_ABC123');
        await driver.updateWifiSettings(w.copyWith(ssid: 'NetPulse', password: 'newpassword1', maxClients: 10));
        expect(server.wlan['SSID'], 'NetPulse');
        expect(server.wlan['wpaPsk'], 'newpassword1');
        expect(server.wlan['MaxAssociatedDevices'], 10);
        expect(server.staleCsrfRejections, 0);
      });

      test('DNS preset (router rejects echoed IPv6_IdentifierType, as on real hardware)', () async {
        expect((await driver.getDns()).primary, isNull);
        await driver.setDns(DnsSettings.fromPreset(DnsPreset.adguardFamily));
        expect(server.lan['DNSServer1'], '94.140.14.15');
        expect(server.lan['DNSType'], 'Static');
        expect(server.lan['IPAddress'], '192.168.1.1', reason: 'LAN IP untouched');
        expect((await driver.getDns()).primary, '94.140.14.15');
        await driver.setDns(const DnsSettings());
        expect((await driver.getDns()).primary, isNull);
      });

      test('re-logs in after the router drops an idle session', () async {
        await driver.login();
        server.expireSessions();
        expect((await driver.getTrafficCounters()).rxBytes, server.rxBytes);
        expect(server.loginCount, 2);
      });

      test('logout frees the single admin session', () async {
        await driver.login();
        await driver.logout();
        expect(server.logoutCount, 1);
        expect(driver.isLoggedIn, isFalse);
      });

      test('trace and errors never contain passwords or session keys', () async {
        await driver.login();
        await driver.getRouterStatus();
        await driver.getWifiSettings();
        await driver.setWifiSpeedLimit(SpeedLimit.mbps(2));
        // (The password happens to equal the end of the serial number,
        // S000H11223344, which is not secret — so match it as a whole word.)
        final standalonePass = RegExp(r'(?<![0-9A-Za-z])11223344(?![0-9])');
        final all = trace.join('\n');
        expect(standalonePass.hasMatch(all), isFalse);
        expect(all, isNot(contains('sessionkey":"')));
        final raw = await driver.rawDal('cardpage_status');
        expect(standalonePass.hasMatch('$raw'), isFalse, reason: 'WiFiInfo.wifiPassword must be redacted');
        expect('$raw', contains('wifiPassword: ***'));
      });
    });
  }

  group('error cases', () {
    late FakeZyxelServer server;
    setUp(() async {
      server = FakeZyxelServer();
      await server.start();
    });
    tearDown(() => server.stop());

    ZyxelVmg3625Driver make(String pass) => ZyxelVmg3625Driver(
          RouterCredentials(gatewayIp: '127.0.0.1:${server.port}', username: 'admin', password: pass),
        );

    test('wrong password', () async {
      final d = make('nope');
      await expectLater(
          d.login(), throwsA(isA<RouterException>().having((e) => e.code, 'code', RouterErrorCode.invalidCredentials)));
      d.dispose();
    });

    test('another client (browser) holds the admin session', () async {
      server.occupyByOtherClient();
      final d = make(_pass);
      await expectLater(
          d.login(), throwsA(isA<RouterException>().having((e) => e.code, 'code', RouterErrorCode.tooManySessions)));
      d.dispose();
    });

    test('Wi-Fi falls back to the status page when oid=wlan is empty', () async {
      await server.stop();
      server = FakeZyxelServer(wlanAvailable: false);
      await server.start();
      final d = make(_pass);
      final w = await d.getWifiSettings();
      expect(w.ssid, 'WE_ABC123');
      expect(w.password, _pass);
      d.dispose();
    });
  });

  test('unreachable router gives a clear error', () async {
    final d = ZyxelVmg3625Driver(
      const RouterCredentials(gatewayIp: '127.0.0.1:1', username: 'admin', password: 'x'),
    );
    await expectLater(
        d.login(), throwsA(isA<RouterException>().having((e) => e.code, 'code', RouterErrorCode.unreachable)));
    d.dispose();
  });
}
