import 'package:flutter_test/flutter_test.dart';
import 'package:netpulse_router_manager/drivers/mock/mock_router_driver.dart';
import 'package:netpulse_router_manager/drivers/router_driver.dart';

void main() {
  const creds = RouterCredentials(gatewayIp: '192.168.1.1', username: 'admin', password: 'demo');

  test('rejects wrong password', () async {
    final d = MockRouterDriver(const RouterCredentials(gatewayIp: '192.168.1.1', username: 'admin', password: 'x'));
    expect(d.login(), throwsA(isA<RouterException>()));
  });

  test('speed limit caps simulated throughput', () async {
    var now = DateTime(2026, 11, 23, 20);
    final d = MockRouterDriver(creds, clock: () => now);
    await d.login();
    await d.setWifiSpeedLimit(SpeedLimit.mbps(2));
    final a = await d.getTrafficCounters();
    now = now.add(const Duration(seconds: 10));
    final b = await d.getTrafficCounters();
    final mbps = (b.rxBytes - a.rxBytes) * 8 / 10 / 1e6;
    expect(mbps, lessThanOrEqualTo(2.0));
    expect(mbps, greaterThan(1.5));
    expect((await d.getWifiSpeedLimit()).mbps, 2);
  });

  test('wifi settings round-trip and validation', () async {
    final d = MockRouterDriver(creds);
    await d.login();
    final w = await d.getWifiSettings();
    await d.updateWifiSettings(w.copyWith(ssid: 'Test', maxClients: 5));
    expect((await d.getWifiSettings()).ssid, 'Test');
    expect(d.updateWifiSettings(w.copyWith(password: 'short')), throwsA(isA<RouterException>()));
  });
}
