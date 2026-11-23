import 'package:flutter_test/flutter_test.dart';
import 'package:netpulse_router_manager/drivers/router_driver.dart';
import 'package:netpulse_router_manager/drivers/zyxel/zyxel_vmg3625_driver.dart';

import 'fake_zyxel_server.dart';

void main() {
  for (final encrypted in [true, false]) {
    group(encrypted ? 'encrypted firmware' : 'plain-JSON firmware', () {
      late FakeZyxelServer server;
      late ZyxelVmg3625Driver driver;
      final trace = <String>[];

      setUp(() async {
        server = FakeZyxelServer(encrypted: encrypted);
        await server.start();
        trace.clear();
        driver = ZyxelVmg3625Driver(
          RouterCredentials(gatewayIp: '127.0.0.1:${server.port}', username: 'admin', password: 'S3cret!'),
          trace: trace.add,
        );
      });

      tearDown(() async {
        driver.dispose();
        await server.stop();
      });

      test('login + status + counters', () async {
        await driver.login();
        expect(driver.isLoggedIn, isTrue);
        expect(driver.encrypted, encrypted);

        final st = await driver.getRouterStatus();
        expect(st.model, 'VMG3625-T50B');
        expect(st.connected, isTrue);
        expect(st.wanIp, '41.235.18.77', reason: 'must skip LAN/IPTV rows');
        expect(st.dslDownstreamKbps, 51200);
        expect(st.uptime, const Duration(seconds: 93784));

        final c = await driver.getTrafficCounters();
        expect(c.rxBytes, server.rxBytes, reason: 'WAN row, not the busier LAN bridge');
        expect(c.txBytes, server.txBytes);
      });

      test('wrong password is reported as invalid credentials', () async {
        final bad = ZyxelVmg3625Driver(
          RouterCredentials(gatewayIp: '127.0.0.1:${server.port}', username: 'admin', password: 'nope'),
        );
        await expectLater(
          bad.login(),
          throwsA(isA<RouterException>().having((e) => e.code, 'code', RouterErrorCode.invalidCredentials)),
        );
        bad.dispose();
      });

      test('re-logs in transparently after the router drops the session', () async {
        await driver.login();
        server.expireSessions();
        final c = await driver.getTrafficCounters();
        expect(c.rxBytes, server.rxBytes);
        expect(server.loginCount, 2);
      });

      test('devices', () async {
        final devices = await driver.getConnectedDevices();
        expect(devices, hasLength(3));
        expect(devices[0].band, WifiBand.band5);
        expect(devices[0].mac, 'A4:C3:F0:12:9B:01');
        expect(devices[1].band, WifiBand.ethernet);
        expect(devices[1].name, '00:1B:21:3C:8D:50', reason: 'falls back to MAC');
        expect(devices[2].band, WifiBand.band24);
        expect(devices[2].active, isFalse);
      });

      test('wifi settings round-trip keeps firmware key names', () async {
        final w = await driver.getWifiSettings();
        expect(w.ssid, 'ZYXEL_HOME');
        await driver.updateWifiSettings(w.copyWith(ssid: 'NetPulse', password: 'newpassword1', maxClients: 10));
        expect(server.wlan['SSID'], 'NetPulse');
        expect(server.wlan['wpaPsk'], 'newpassword1');
        expect(server.wlan['MaxAssociatedDevices'], 10);
        expect(server.wlan.containsKey('KeyPassphrase'), isFalse);
      });

      test('DNS preset', () async {
        expect((await driver.getDns()).primary, isNull);
        await driver.setDns(DnsSettings.fromPreset(DnsPreset.cloudflare));
        expect(server.lan['DNSType'], 'Static');
        expect(server.lan['DNSServer1'], '1.1.1.1');
        expect((await driver.getDns()).primary, '1.1.1.1');
      });

      test('speed limit uses the Wi-Fi shaper row and enables QoS', () async {
        final r = await driver.setWifiSpeedLimit(SpeedLimit.mbps(6));
        expect(r.success, isTrue);
        expect(server.qosEnabled, isTrue);
        expect(server.shaper[1]['Enable'], isTrue);
        expect(server.shaper[1]['ShapingRate'], 6000);
        expect(server.shaper[0]['Enable'], isFalse, reason: 'WAN shaper untouched');
        expect((await driver.getWifiSpeedLimit()).mbps, 6);

        await driver.setWifiSpeedLimit(const SpeedLimit.unlimited());
        expect(server.shaper[1]['Enable'], isFalse);
        expect((await driver.getWifiSpeedLimit()).isUnlimited, isTrue);
      });

      test('logout frees the session', () async {
        await driver.login();
        await driver.logout();
        expect(server.logoutCount, 1);
        expect(driver.isLoggedIn, isFalse);
      });

      test('trace never contains the password', () async {
        await driver.login();
        await driver.getRouterStatus();
        expect(trace, isNotEmpty);
        expect(trace.join('\n'), isNot(contains('S3cret!')));
      });
    });
  }

  test('unreachable router gives a clear error', () async {
    final d = ZyxelVmg3625Driver(
      const RouterCredentials(gatewayIp: '127.0.0.1:1', username: 'admin', password: 'x'),
    );
    await expectLater(
      d.login(),
      throwsA(isA<RouterException>().having((e) => e.code, 'code', RouterErrorCode.unreachable)),
    );
    d.dispose();
  });
}
