import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:netpulse_router_manager/core/notifications/usage_alerts.dart';
import 'package:netpulse_router_manager/features/usage/domain/usage_calculator_service.dart';
import 'package:netpulse_router_manager/features/usage/domain/usage_models.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  final svc = UsageCalculatorService();
  final now = DateTime(2026, 11, 20);
  const quota = QuotaSettings(quotaGb: 100);

  // flutter test reports Android; use a platform without the native plugin.
  setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.linux);
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  UsageStats statsAt(double usedGb) {
    final l = UsageLedger()..daily['2026-11-10'] = DailyUsage(rx: gbToBytes(usedGb));
    return svc.stats(l, quota, now);
  }

  test('each threshold fires once per cycle', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();

    expect(await UsageAlerts.check(prefs, statsAt(50), demo: false), isNull);
    expect(await UsageAlerts.check(prefs, statsAt(76), demo: false), 75);
    expect(await UsageAlerts.check(prefs, statsAt(80), demo: false), isNull, reason: 'already sent');
    expect(await UsageAlerts.check(prefs, statsAt(92), demo: false), 90);
    expect(await UsageAlerts.check(prefs, statsAt(101), demo: false), 100);
    expect(await UsageAlerts.check(prefs, statsAt(105), demo: false), isNull);
  });

  test('demo and real alerts are tracked separately', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    expect(await UsageAlerts.check(prefs, statsAt(80), demo: true), 75);
    expect(await UsageAlerts.check(prefs, statsAt(80), demo: false), 75);
  });

  test('new cycle re-arms alerts', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    expect(await UsageAlerts.check(prefs, statsAt(80), demo: false), 75);
    final l = UsageLedger()..daily['2026-12-03'] = DailyUsage(rx: gbToBytes(80));
    expect(await UsageAlerts.check(prefs, svc.stats(l, quota, DateTime(2026, 12, 5)), demo: false), 75);
  });
}
