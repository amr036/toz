import 'package:flutter_test/flutter_test.dart';
import 'package:netpulse_router_manager/drivers/router_models.dart';
import 'package:netpulse_router_manager/features/usage/domain/usage_calculator_service.dart';
import 'package:netpulse_router_manager/features/usage/domain/usage_models.dart';

TrafficCounters c(int rx, int tx, DateTime t) => TrafficCounters(rxBytes: rx, txBytes: tx, timestamp: t);

void main() {
  final svc = UsageCalculatorService();
  const gb = bytesPerGb;

  group('counterDelta', () {
    test('first sample is a baseline', () {
      expect(UsageCalculatorService.counterDelta(null, 500), (0, IngestEvent.baseline));
    });
    test('normal increase', () {
      expect(UsageCalculatorService.counterDelta(100, 350), (250, IngestEvent.normal));
    });
    test('router reboot: new value is traffic since boot', () {
      expect(UsageCalculatorService.counterDelta(9 * gb, 200), (200, IngestEvent.counterReset));
    });
    test('32-bit wrap', () {
      const last = 0xFFFFFF00; // 2^32 - 256
      expect(UsageCalculatorService.counterDelta(last, 100), (356, IngestEvent.counterWrap));
    });
  });

  group('ingest', () {
    test('accumulates deltas per day and survives a reboot', () {
      final l = UsageLedger();
      final t0 = DateTime(2026, 11, 10, 10);
      expect(svc.ingest(l, c(5 * gb, 1 * gb, t0)), IngestEvent.baseline);
      expect(l.daily, isEmpty);

      svc.ingest(l, c(6 * gb, gb + gb ~/ 2, t0.add(const Duration(hours: 1))));
      expect(l.daily[dayKey(t0)]!.rx, gb);
      expect(l.daily[dayKey(t0)]!.tx, gb ~/ 2);

      // Router reboots, comes back having counted 0.3 GB since boot.
      final ev = svc.ingest(l, c(3 * gb ~/ 10, 0, t0.add(const Duration(hours: 2))));
      expect(ev, IngestEvent.counterReset);
      expect(l.resetCount, 1);
      expect(l.daily[dayKey(t0)]!.rx, gb + 3 * gb ~/ 10);
    });

    test('rejects physically impossible jumps', () {
      final l = UsageLedger();
      final t0 = DateTime(2026, 11, 10, 10);
      svc.ingest(l, c(0, 0, t0));
      // 500 GB in 5 seconds is impossible on a 1 Gbps link.
      final ev = svc.ingest(l, c(500 * gb, 0, t0.add(const Duration(seconds: 5))));
      expect(ev, IngestEvent.glitchIgnored);
      expect(l.daily, isEmpty);
      expect(l.lastRawRx, 500 * gb, reason: 're-baselined');
    });

    test('splits traffic across midnight', () {
      final l = UsageLedger();
      final t0 = DateTime(2026, 11, 10, 23, 59);
      svc.ingest(l, c(0, 0, t0));
      svc.ingest(l, c(gb, 0, DateTime(2026, 11, 10, 23, 59, 50)));
      svc.ingest(l, c(2 * gb, 0, DateTime(2026, 11, 11, 0, 0, 30)));
      expect(l.daily['2026-11-10']!.rx, gb);
      expect(l.daily['2026-11-11']!.rx, gb);
    });
  });

  group('billing cycle', () {
    test('renewal day later in month → cycle started last month', () {
      final cy = UsageCalculatorService.cycleFor(DateTime(2026, 11, 5), 20);
      expect(cy.start, DateTime(2026, 10, 20));
      expect(cy.end, DateTime(2026, 11, 20));
      expect(cy.lengthDays, 31);
    });
    test('renewal day 31 clamps to short months', () {
      final cy = UsageCalculatorService.cycleFor(DateTime(2026, 2, 28, 12), 31);
      expect(cy.start, DateTime(2026, 2, 28));
      expect(cy.end, DateTime(2026, 3, 31));
    });
    test('year boundary', () {
      final cy = UsageCalculatorService.cycleFor(DateTime(2027, 1, 3), 15);
      expect(cy.start, DateTime(2026, 12, 15));
      expect(cy.end, DateTime(2027, 1, 15));
    });
  });

  group('stats', () {
    test('averages, projection and days left', () {
      final l = UsageLedger();
      const q = QuotaSettings(quotaGb: 140, renewalDay: 1);
      // 10 days × 5 GB in a 30-day month (November).
      for (var d = 1; d <= 10; d++) {
        l.daily[dayKey(DateTime(2026, 11, d))] = DailyUsage(rx: 4 * gb, tx: gb);
      }
      final s = svc.stats(l, q, DateTime(2026, 11, 11)); // exactly 10 days elapsed
      expect(s.usedBytes, 50 * gb);
      expect(s.remainingBytes, 90 * gb);
      expect(s.percent, closeTo(35.71, 0.01));
      expect(s.dailyAverageBytes, closeTo(5 * gb, 1));
      expect(s.projectedCycleBytes, closeTo(150 * gb, 1));
      expect(s.projectedToExceed, isTrue);
      expect(s.daysUntilExhausted, closeTo(18, 0.001));
      expect(s.daysLeftInCycle, closeTo(20, 0.001));
      expect(s.dailyBudgetBytes, closeTo(4.5 * gb, 1));
      expect(s.warning, UsageWarning.none);
    });

    test('upload excluded when countUpload is off', () {
      final l = UsageLedger()..daily['2026-11-02'] = const DailyUsage(rx: 4 * gb, tx: gb);
      final s = svc.stats(l, const QuotaSettings(countUpload: false), DateTime(2026, 11, 3));
      expect(s.usedBytes, 4 * gb);
    });

    test('warning thresholds', () {
      UsageWarning w(double usedGb) {
        final l = UsageLedger()..daily['2026-11-02'] = DailyUsage(rx: gbToBytes(usedGb));
        return svc.stats(l, const QuotaSettings(quotaGb: 100), DateTime(2026, 11, 3)).warning;
      }

      expect(w(74), UsageWarning.none);
      expect(w(75), UsageWarning.p75);
      expect(w(91), UsageWarning.p90);
      expect(w(100), UsageWarning.p100);
    });

    test('previous cycle days are not counted', () {
      final l = UsageLedger()
        ..daily['2026-10-31'] = const DailyUsage(rx: 50 * gb)
        ..daily['2026-11-01'] = const DailyUsage(rx: 2 * gb);
      final s = svc.stats(l, const QuotaSettings(renewalDay: 1), DateTime(2026, 11, 1, 18));
      expect(s.usedBytes, 2 * gb);
    });
  });

  group('calibration', () {
    test('matches ISP figure and only applies to its cycle', () {
      final l = UsageLedger()..daily['2026-11-05'] = const DailyUsage(rx: 30 * gb, tx: 2 * gb);
      const q = QuotaSettings(renewalDay: 1);
      final now = DateTime(2026, 11, 6);
      svc.calibrate(l, q, 41.5, now);
      expect(svc.stats(l, q, now).usedBytes, gbToBytes(41.5));
      // Next cycle: adjustment no longer applies.
      expect(svc.stats(l, q, DateTime(2026, 12, 2)).usedBytes, 0);
      svc.clearCalibration(l);
      expect(svc.stats(l, q, now).usedBytes, 32 * gb);
    });

    test('ledger JSON round-trip', () {
      final l = UsageLedger(lastRawRx: 5, lastRawTx: 6, lastSampleAt: DateTime(2026, 11, 1))
        ..daily['2026-11-01'] = const DailyUsage(rx: 1, tx: 2)
        ..calibrationCycleKey = '2026-11-01'
        ..calibrationAdjustBytes = -42;
      final r = l.clone();
      expect(r.lastRawRx, 5);
      expect(r.daily['2026-11-01']!.tx, 2);
      expect(r.calibrationAdjustBytes, -42);
    });
  });
}
