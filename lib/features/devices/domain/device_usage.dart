import 'dart:math';

import '../../../drivers/router_models.dart';
import '../../usage/domain/usage_calculator_service.dart';
import '../../usage/domain/usage_models.dart';

/// Per-device history, keyed by MAC address.
class DeviceTrack {
  DeviceTrack({
    required this.mac,
    this.lastName,
    this.nickname,
    this.lastDown,
    this.lastUp,
    this.lastSampleAt,
    this.lastSeen,
    Map<String, DailyUsage>? daily,
  }) : daily = daily ?? {};

  final String mac;
  String? lastName;

  /// Name the user gave the device in the app (router names are often just
  /// the MAC on phones that use private addresses).
  String? nickname;
  int? lastDown;
  int? lastUp;
  DateTime? lastSampleAt;
  DateTime? lastSeen;

  /// yyyy-MM-dd → bytes (rx = downloaded by the device, tx = uploaded).
  final Map<String, DailyUsage> daily;

  String get displayName => (nickname?.isNotEmpty ?? false) ? nickname! : (lastName ?? mac);

  Map<String, dynamic> toJson() => {
        'mac': mac,
        'lastName': lastName,
        'nickname': nickname,
        'lastDown': lastDown,
        'lastUp': lastUp,
        'lastSampleAt': lastSampleAt?.toIso8601String(),
        'lastSeen': lastSeen?.toIso8601String(),
        'daily': daily.map((k, v) => MapEntry(k, v.toJson())),
      };

  factory DeviceTrack.fromJson(Map<String, dynamic> j) => DeviceTrack(
        mac: j['mac'] as String,
        lastName: j['lastName'] as String?,
        nickname: j['nickname'] as String?,
        lastDown: (j['lastDown'] as num?)?.toInt(),
        lastUp: (j['lastUp'] as num?)?.toInt(),
        lastSampleAt: j['lastSampleAt'] == null ? null : DateTime.parse(j['lastSampleAt'] as String),
        lastSeen: j['lastSeen'] == null ? null : DateTime.parse(j['lastSeen'] as String),
        daily: (j['daily'] as Map?)?.map(
              (k, v) => MapEntry(k as String, DailyUsage.fromJson(Map<String, dynamic>.from(v as Map))),
            ) ??
            {},
      );
}

class DeviceLedger {
  DeviceLedger([Map<String, DeviceTrack>? devices]) : devices = devices ?? {};
  final Map<String, DeviceTrack> devices;

  DeviceLedger clone() => DeviceLedger.fromJson(toJson());

  Map<String, dynamic> toJson() => {'devices': devices.map((k, v) => MapEntry(k, v.toJson()))};

  factory DeviceLedger.fromJson(Map<String, dynamic> j) => DeviceLedger(
        (j['devices'] as Map?)?.map(
              (k, v) => MapEntry(k as String, DeviceTrack.fromJson(Map<String, dynamic>.from(v as Map))),
            ) ??
            {},
      );
}

class DeviceCycleUsage {
  const DeviceCycleUsage({
    required this.track,
    required this.cycleBytes,
    required this.todayBytes,
    required this.shareOfQuota,
    required this.shareOfDevices,
  });

  final DeviceTrack track;
  final int cycleBytes;
  final int todayBytes;

  /// Fraction (0-1) of the monthly quota this device used this cycle.
  final double shareOfQuota;

  /// Fraction (0-1) of all devices' traffic this cycle.
  final double shareOfDevices;
}

/// Same delta logic as the WAN counter (see [UsageCalculatorService]), applied
/// to each device's lanhosts counters. Those reset when the device reconnects
/// or the router reboots, which is handled as a counter reset.
class DeviceUsageService {
  DeviceUsageService({this.maxLinkMbps = 1000, this.historyDays = 120});

  final double maxLinkMbps;
  final int historyDays;

  void ingest(DeviceLedger ledger, List<ConnectedDevice> devices, DateTime now) {
    final key = dayKey(now);
    for (final d in devices) {
      final mac = d.mac.toUpperCase();
      if (mac.isEmpty) continue;
      final t = ledger.devices.putIfAbsent(mac, () => DeviceTrack(mac: mac));
      if (d.name != d.mac) t.lastName = d.name;
      t.lastSeen = now;
      final down = d.downloadedBytes;
      final up = d.uploadedBytes;
      if (down == null || up == null) continue;

      final (dDown, eDown) = UsageCalculatorService.counterDelta(t.lastDown, down);
      final (dUp, eUp) = UsageCalculatorService.counterDelta(t.lastUp, up);
      final prev = t.lastSampleAt;
      t
        ..lastDown = down
        ..lastUp = up
        ..lastSampleAt = now;
      if (eDown == IngestEvent.baseline || eUp == IngestEvent.baseline) continue;
      if (prev != null) {
        final secs = max(1, now.difference(prev).inSeconds);
        final maxBytes = maxLinkMbps * 1e6 / 8 * secs * 1.25 + 50 * 1024 * 1024;
        final reset = eDown == IngestEvent.counterReset || eUp == IngestEvent.counterReset;
        if (!reset && (dDown > maxBytes || dUp > maxBytes)) continue;
      }
      if (dDown == 0 && dUp == 0) continue;
      t.daily[key] = (t.daily[key] ?? const DailyUsage()).add(dDown, dUp);
    }
    final cutoff = dayKey(now.subtract(Duration(days: historyDays)));
    for (final t in ledger.devices.values) {
      t.daily.removeWhere((k, _) => k.compareTo(cutoff) < 0);
    }
    ledger.devices.removeWhere(
      (_, t) => t.daily.isEmpty && (t.lastSeen == null || now.difference(t.lastSeen!).inDays > historyDays),
    );
  }

  /// Per-device totals for the current billing cycle, biggest first.
  List<DeviceCycleUsage> cycleUsage(DeviceLedger ledger, QuotaSettings quota, DateTime now) {
    final cycle = UsageCalculatorService.cycleFor(now, quota.renewalDay);
    final today = dayKey(now);
    final rows = <({DeviceTrack t, int cycle, int today})>[];
    for (final t in ledger.devices.values) {
      var c = 0;
      t.daily.forEach((k, v) {
        if (cycle.contains(parseDayKey(k))) c += v.total(countUpload: quota.countUpload);
      });
      rows.add((t: t, cycle: c, today: t.daily[today]?.total(countUpload: quota.countUpload) ?? 0));
    }
    final total = rows.fold<int>(0, (a, r) => a + r.cycle);
    rows.sort((a, b) => b.cycle.compareTo(a.cycle));
    return [
      for (final r in rows)
        DeviceCycleUsage(
          track: r.t,
          cycleBytes: r.cycle,
          todayBytes: r.today,
          shareOfQuota: quota.quotaBytes <= 0 ? 0 : r.cycle / quota.quotaBytes,
          shareOfDevices: total == 0 ? 0 : r.cycle / total,
        ),
    ];
  }

  /// DEMO MODE ONLY: spreads the demo WAN history over the demo devices so
  /// the per-device view isn't empty on first launch.
  static void seedDemo(DeviceLedger ledger, UsageLedger wan, Map<String, (String, double)> devices) {
    if (ledger.devices.isNotEmpty) return;
    devices.forEach((mac, info) {
      final (name, share) = info;
      ledger.devices[mac] = DeviceTrack(
        mac: mac,
        lastName: name,
        daily: {
          for (final e in wan.daily.entries)
            e.key: DailyUsage(rx: (e.value.rx * share).round(), tx: (e.value.tx * share).round()),
        },
      );
    });
  }
}
