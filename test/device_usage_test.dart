import 'package:flutter_test/flutter_test.dart';
import 'package:netpulse_router_manager/drivers/router_models.dart';
import 'package:netpulse_router_manager/features/devices/domain/device_usage.dart';
import 'package:netpulse_router_manager/features/usage/domain/usage_models.dart';

ConnectedDevice dev(String mac, int down, int up, {String name = 'x'}) => ConnectedDevice(
    name: name, ip: '1', mac: mac, band: WifiBand.band24, downloadedBytes: down, uploadedBytes: up);

void main() {
  final svc = DeviceUsageService();
  const gb = bytesPerGb;
  final t0 = DateTime(2026, 11, 20, 10);

  test('accumulates deltas per device and survives reconnect resets', () {
    final l = DeviceLedger();
    svc.ingest(l, [dev('AA', 10 * gb, gb), dev('BB', 0, 0)], t0); // baseline
    svc.ingest(l, [dev('AA', 12 * gb, gb), dev('BB', gb, 0)], t0.add(const Duration(hours: 1)));
    // AA reconnects: its counters restart from zero.
    svc.ingest(l, [dev('AA', gb ~/ 2, 0), dev('BB', gb, 0)], t0.add(const Duration(hours: 2)));

    final rows = svc.cycleUsage(l, const QuotaSettings(quotaGb: 100), t0.add(const Duration(hours: 3)));
    expect(rows.first.track.mac, 'AA');
    expect(rows.first.cycleBytes, 2 * gb + gb ~/ 2);
    expect(rows.first.shareOfQuota, closeTo(0.025, 1e-9));
    expect(rows[1].cycleBytes, gb);
    expect(rows.first.shareOfDevices + rows[1].shareOfDevices, closeTo(1, 1e-9));
  });

  test('upload excluded when the quota does not count it', () {
    final l = DeviceLedger();
    svc.ingest(l, [dev('AA', 0, 0)], t0);
    svc.ingest(l, [dev('AA', gb, gb)], t0.add(const Duration(minutes: 30)));
    final rows = svc.cycleUsage(l, const QuotaSettings(countUpload: false), t0.add(const Duration(hours: 1)));
    expect(rows.single.cycleBytes, gb);
  });

  test('nickname wins over router name; ledger survives JSON', () {
    final l = DeviceLedger();
    svc.ingest(l, [dev('AA', 0, 0, name: 'android-1234')], t0);
    l.devices['AA']!.nickname = 'Ahmed phone';
    final r = l.clone();
    expect(r.devices['AA']!.displayName, 'Ahmed phone');
    expect(r.devices['AA']!.lastName, 'android-1234');
  });
}
