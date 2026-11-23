import 'dart:math';

/// Bytes in one GB as ISPs bill it. Most Egyptian / MENA ISPs (WE, Orange,
/// Vodafone, Etisalat) use decimal GB; switch to 1024³ if your portal differs.
const int bytesPerGb = 1000 * 1000 * 1000;

double bytesToGb(num bytes) => bytes / bytesPerGb;
int gbToBytes(num gb) => (gb * bytesPerGb).round();

class QuotaSettings {
  const QuotaSettings({
    this.quotaGb = 140,
    this.renewalDay = 1,
    this.countUpload = true,
  });

  /// Monthly quota in GB.
  final double quotaGb;

  /// Day of month the bundle renews (1-31; clamped for short months).
  final int renewalDay;

  /// Most ISPs count download + upload. Turn off if yours only counts download.
  final bool countUpload;

  int get quotaBytes => gbToBytes(quotaGb);

  QuotaSettings copyWith({double? quotaGb, int? renewalDay, bool? countUpload}) => QuotaSettings(
        quotaGb: quotaGb ?? this.quotaGb,
        renewalDay: renewalDay ?? this.renewalDay,
        countUpload: countUpload ?? this.countUpload,
      );

  Map<String, dynamic> toJson() =>
      {'quotaGb': quotaGb, 'renewalDay': renewalDay, 'countUpload': countUpload};

  factory QuotaSettings.fromJson(Map<String, dynamic> j) => QuotaSettings(
        quotaGb: (j['quotaGb'] as num?)?.toDouble() ?? 140,
        renewalDay: (j['renewalDay'] as num?)?.toInt() ?? 1,
        countUpload: j['countUpload'] as bool? ?? true,
      );
}

class DailyUsage {
  const DailyUsage({this.rx = 0, this.tx = 0});
  final int rx;
  final int tx;

  int total({bool countUpload = true}) => rx + (countUpload ? tx : 0);

  DailyUsage add(int dRx, int dTx) => DailyUsage(rx: rx + dRx, tx: tx + dTx);

  Map<String, dynamic> toJson() => {'rx': rx, 'tx': tx};
  factory DailyUsage.fromJson(Map<String, dynamic> j) =>
      DailyUsage(rx: (j['rx'] as num?)?.toInt() ?? 0, tx: (j['tx'] as num?)?.toInt() ?? 0);
}

/// Persistent local snapshot of everything needed to keep counting across
/// app restarts and router reboots.
class UsageLedger {
  UsageLedger({
    this.lastRawRx,
    this.lastRawTx,
    this.lastSampleAt,
    Map<String, DailyUsage>? daily,
    this.calibrationCycleKey,
    this.calibrationAdjustBytes = 0,
    this.resetCount = 0,
    this.lastResetAt,
  }) : daily = daily ?? {};

  /// Last raw counter values read from the router (null = no baseline yet).
  int? lastRawRx;
  int? lastRawTx;
  DateTime? lastSampleAt;

  /// yyyy-MM-dd → bytes counted on that local day.
  final Map<String, DailyUsage> daily;

  /// Calibration only applies to the billing cycle it was entered in.
  String? calibrationCycleKey;
  int calibrationAdjustBytes;

  /// Number of router counter resets (reboots) detected.
  int resetCount;
  DateTime? lastResetAt;

  UsageLedger clone() => UsageLedger.fromJson(toJson());

  Map<String, dynamic> toJson() => {
        'lastRawRx': lastRawRx,
        'lastRawTx': lastRawTx,
        'lastSampleAt': lastSampleAt?.toIso8601String(),
        'daily': daily.map((k, v) => MapEntry(k, v.toJson())),
        'calibrationCycleKey': calibrationCycleKey,
        'calibrationAdjustBytes': calibrationAdjustBytes,
        'resetCount': resetCount,
        'lastResetAt': lastResetAt?.toIso8601String(),
      };

  factory UsageLedger.fromJson(Map<String, dynamic> j) => UsageLedger(
        lastRawRx: (j['lastRawRx'] as num?)?.toInt(),
        lastRawTx: (j['lastRawTx'] as num?)?.toInt(),
        lastSampleAt: j['lastSampleAt'] == null ? null : DateTime.parse(j['lastSampleAt'] as String),
        daily: (j['daily'] as Map?)?.map(
              (k, v) => MapEntry(k as String, DailyUsage.fromJson(Map<String, dynamic>.from(v as Map))),
            ) ??
            {},
        calibrationCycleKey: j['calibrationCycleKey'] as String?,
        calibrationAdjustBytes: (j['calibrationAdjustBytes'] as num?)?.toInt() ?? 0,
        resetCount: (j['resetCount'] as num?)?.toInt() ?? 0,
        lastResetAt: j['lastResetAt'] == null ? null : DateTime.parse(j['lastResetAt'] as String),
      );
}

class BillingCycle {
  const BillingCycle(this.start, this.end);

  /// Inclusive local midnight of the renewal day.
  final DateTime start;

  /// Exclusive — the next renewal.
  final DateTime end;

  int get lengthDays => (end.difference(start).inHours / 24).round(); // DST-safe

  String get key => dayKey(start);

  bool contains(DateTime t) => !t.isBefore(start) && t.isBefore(end);
}

String dayKey(DateTime t) =>
    '${t.year.toString().padLeft(4, '0')}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';

DateTime parseDayKey(String k) {
  final p = k.split('-').map(int.parse).toList();
  return DateTime(p[0], p[1], p[2]);
}

enum UsageWarning { none, p75, p90, p100 }

class UsageStats {
  const UsageStats({
    required this.cycle,
    required this.quotaBytes,
    required this.usedBytes,
    required this.daysElapsed,
    required this.daysLeftInCycle,
  });

  final BillingCycle cycle;
  final int quotaBytes;
  final int usedBytes;

  /// Fractional days since the cycle started.
  final double daysElapsed;

  /// Fractional days until renewal.
  final double daysLeftInCycle;

  int get remainingBytes => max(0, quotaBytes - usedBytes);

  double get percent => quotaBytes <= 0 ? 0 : usedBytes / quotaBytes * 100;

  /// Average per day so far (at least one day is assumed, so the first hours
  /// of a cycle don't produce absurd projections).
  double get dailyAverageBytes => usedBytes / max(1.0, daysElapsed);

  /// What you'll have used at renewal if you keep this pace.
  double get projectedCycleBytes => dailyAverageBytes * cycle.lengthDays;

  bool get projectedToExceed => projectedCycleBytes > quotaBytes;

  /// Days until the quota runs out at the current pace (null = never / no usage).
  double? get daysUntilExhausted {
    if (remainingBytes == 0) return 0;
    if (dailyAverageBytes <= 0) return null;
    return remainingBytes / dailyAverageBytes;
  }

  /// Budget per remaining day to land exactly on the quota.
  double get dailyBudgetBytes => remainingBytes / max(1.0, daysLeftInCycle);

  UsageWarning get warning {
    final p = percent;
    if (p >= 100) return UsageWarning.p100;
    if (p >= 90) return UsageWarning.p90;
    if (p >= 75) return UsageWarning.p75;
    return UsageWarning.none;
  }
}

class DailyPoint {
  const DailyPoint(this.day, this.rx, this.tx);
  final DateTime day;
  final int rx;
  final int tx;
  int total(bool countUpload) => rx + (countUpload ? tx : 0);
}

enum IngestEvent { baseline, normal, counterReset, counterWrap, glitchIgnored }
