import 'dart:math';

import '../../../drivers/router_models.dart';
import 'usage_models.dart';

/// Pure, side-effect-free usage math. Persistence lives in UsageRepository.
///
/// Key ideas:
///  * Router counters are cumulative since *router boot*. We keep the last
///    raw value and only ever add the positive **delta** to the local ledger.
///  * If a counter goes backwards the router rebooted (or a 32-bit counter
///    wrapped). On reboot the new raw value itself is the traffic since boot.
///  * Usage is stored per local day; the billing-cycle total is the sum of
///    the days inside the cycle (+ an optional calibration offset). So cycle
///    rollover needs no special event and changing the renewal day just works.
class UsageCalculatorService {
  UsageCalculatorService({
    this.maxLinkMbps = 1000,
    this.historyDays = 120,
  });

  /// Upper bound used to reject impossible deltas (e.g. a buggy firmware
  /// briefly reporting garbage).
  final double maxLinkMbps;

  /// Daily entries older than this are pruned.
  final int historyDays;

  static const int _wrap32 = 0x100000000; // 2^32

  // ---------------------------------------------------------------------------
  // Counter ingestion
  // ---------------------------------------------------------------------------

  /// Computes the delta for one counter. Returns (delta, event).
  static (int, IngestEvent) counterDelta(int? last, int current) {
    if (last == null) return (0, IngestEvent.baseline);
    if (current >= last) return (current - last, IngestEvent.normal);

    // Went backwards. A 32-bit wrap looks like: last close to 2^32, current small.
    if (last < _wrap32 && last > (_wrap32 * 0.75) && current < (_wrap32 * 0.25)) {
      return (current + _wrap32 - last, IngestEvent.counterWrap);
    }
    // Otherwise the router rebooted / counters were cleared: everything
    // counted since boot is new traffic.
    return (current, IngestEvent.counterReset);
  }

  /// Applies a new counter sample to [ledger] (mutates it) and returns what
  /// happened.
  IngestEvent ingest(UsageLedger ledger, TrafficCounters sample) {
    final now = sample.timestamp;
    final (dRx, eRx) = counterDelta(ledger.lastRawRx, sample.rxBytes);
    final (dTx, eTx) = counterDelta(ledger.lastRawTx, sample.txBytes);

    final previousSample = ledger.lastSampleAt;
    ledger
      ..lastRawRx = sample.rxBytes
      ..lastRawTx = sample.txBytes
      ..lastSampleAt = now;

    if (eRx == IngestEvent.baseline || eTx == IngestEvent.baseline) {
      return IngestEvent.baseline;
    }

    // Sanity check against the physical maximum of the link.
    if (previousSample != null) {
      final secs = max(1, now.difference(previousSample).inSeconds);
      final maxBytes = maxLinkMbps * 1e6 / 8 * secs * 1.25 + 50 * 1024 * 1024;
      final resetInvolved = eRx == IngestEvent.counterReset || eTx == IngestEvent.counterReset;
      if (!resetInvolved && (dRx > maxBytes || dTx > maxBytes)) {
        return IngestEvent.glitchIgnored; // re-baselined above, nothing counted
      }
    }

    final key = dayKey(now);
    ledger.daily[key] = (ledger.daily[key] ?? const DailyUsage()).add(dRx, dTx);
    _prune(ledger, now);

    if (eRx == IngestEvent.counterReset || eTx == IngestEvent.counterReset) {
      ledger
        ..resetCount += 1
        ..lastResetAt = now;
      return IngestEvent.counterReset;
    }
    if (eRx == IngestEvent.counterWrap || eTx == IngestEvent.counterWrap) {
      return IngestEvent.counterWrap;
    }
    return IngestEvent.normal;
  }

  void _prune(UsageLedger ledger, DateTime now) {
    final cutoff = dayKey(now.subtract(Duration(days: historyDays)));
    ledger.daily.removeWhere((k, _) => k.compareTo(cutoff) < 0);
  }

  // ---------------------------------------------------------------------------
  // Billing cycle
  // ---------------------------------------------------------------------------

  static int daysInMonth(int year, int month) => DateTime(year, month + 1, 0).day;

  static DateTime _renewalIn(int year, int month, int renewalDay) {
    // Normalise month overflow (e.g. month 0 or 13).
    final norm = DateTime(year, month);
    final d = min(max(1, renewalDay), daysInMonth(norm.year, norm.month));
    return DateTime(norm.year, norm.month, d);
  }

  static BillingCycle cycleFor(DateTime now, int renewalDay) {
    var start = _renewalIn(now.year, now.month, renewalDay);
    if (now.isBefore(start)) start = _renewalIn(now.year, now.month - 1, renewalDay);
    final end = _renewalIn(start.year, start.month + 1, renewalDay);
    return BillingCycle(start, end);
  }

  // ---------------------------------------------------------------------------
  // Stats
  // ---------------------------------------------------------------------------

  int rawCycleBytes(UsageLedger ledger, BillingCycle cycle, bool countUpload) {
    var sum = 0;
    ledger.daily.forEach((k, v) {
      if (cycle.contains(parseDayKey(k))) sum += v.total(countUpload: countUpload);
    });
    return sum;
  }

  UsageStats stats(UsageLedger ledger, QuotaSettings quota, DateTime now) {
    final cycle = cycleFor(now, quota.renewalDay);
    var used = rawCycleBytes(ledger, cycle, quota.countUpload);
    if (ledger.calibrationCycleKey == cycle.key) used += ledger.calibrationAdjustBytes;
    used = max(0, used);

    double days(Duration d) => d.inSeconds / 86400.0;
    return UsageStats(
      cycle: cycle,
      quotaBytes: quota.quotaBytes,
      usedBytes: used,
      daysElapsed: days(now.difference(cycle.start)),
      daysLeftInCycle: max(0, days(cycle.end.difference(now))),
    );
  }

  /// Makes "used this cycle" equal [usedGb] (the number shown on your ISP
  /// portal) without rewriting the per-day history.
  void calibrate(UsageLedger ledger, QuotaSettings quota, double usedGb, DateTime now) {
    final cycle = cycleFor(now, quota.renewalDay);
    final raw = rawCycleBytes(ledger, cycle, quota.countUpload);
    ledger
      ..calibrationCycleKey = cycle.key
      ..calibrationAdjustBytes = gbToBytes(usedGb) - raw;
  }

  void clearCalibration(UsageLedger ledger) {
    ledger
      ..calibrationCycleKey = null
      ..calibrationAdjustBytes = 0;
  }

  /// Last [days] local days, oldest first, zero-filled.
  List<DailyPoint> dailySeries(UsageLedger ledger, int days, DateTime now) {
    final today = DateTime(now.year, now.month, now.day);
    return List.generate(days, (i) {
      final d = DateTime(today.year, today.month, today.day - (days - 1 - i));
      final u = ledger.daily[dayKey(d)] ?? const DailyUsage();
      return DailyPoint(d, u.rx, u.tx);
    });
  }

  /// Fills empty history with plausible numbers — DEMO MODE ONLY.
  static void seedDemoHistory(UsageLedger ledger, DateTime now, {int days = 24, int seed = 7}) {
    if (ledger.daily.isNotEmpty) return;
    final r = Random(seed);
    for (var i = days; i >= 1; i--) {
      final d = DateTime(now.year, now.month, now.day - i);
      final weekend = d.weekday == DateTime.friday || d.weekday == DateTime.saturday;
      final gb = (weekend ? 4.6 : 3.2) + r.nextDouble() * 2.2;
      final rx = gbToBytes(gb);
      ledger.daily[dayKey(d)] = DailyUsage(rx: rx, tx: (rx * (0.06 + r.nextDouble() * 0.05)).round());
    }
  }
}
