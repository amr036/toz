/// Plain data models shared by every [RouterDriver] implementation.
///
/// They intentionally have no Flutter dependency so drivers and the usage
/// calculator can be unit-tested with `dart test` / `flutter test`.
library;

enum WifiBand { band24, band5, ethernet, unknown }

enum DnsPreset {
  ispDefault('ISP default', null, null),
  cloudflare('Cloudflare', '1.1.1.1', '1.0.0.1'),
  cloudflareFamily('Cloudflare Family', '1.1.1.3', '1.0.0.3'),
  adguardFamily('AdGuard Family', '94.140.14.15', '94.140.15.16'),
  google('Google', '8.8.8.8', '8.8.4.4'),
  custom('Custom', null, null);

  const DnsPreset(this.label, this.primary, this.secondary);
  final String label;
  final String? primary;
  final String? secondary;

  static DnsPreset match(String? primary) {
    if (primary == null || primary.isEmpty) return DnsPreset.ispDefault;
    for (final p in values) {
      if (p.primary == primary) return p;
    }
    return DnsPreset.custom;
  }
}

/// How a driver is able to enforce a speed limit on this firmware.
enum SpeedLimitMethod {
  /// WAN/LAN QoS shaper (rate limit on an interface / queue).
  qosShaper,

  /// Per-class policer / bandwidth limit rule.
  qosPolicer,

  /// Lowering the Wi-Fi PHY data-rate / mode profile (coarse).
  wifiRateProfile,

  /// Firmware exposes no usable mechanism.
  unsupported,
}

class RouterCapabilities {
  const RouterCapabilities({
    required this.speedLimitMethod,
    this.canSetDns = true,
    this.canReboot = true,
    this.canEditWifi = true,
    this.canLimitClients = true,
    this.canSetTxPower = true,
    this.canBlockDevices = true,
    this.perDeviceTraffic = true,
  });

  final SpeedLimitMethod speedLimitMethod;
  final bool canSetDns;
  final bool canReboot;
  final bool canEditWifi;
  final bool canLimitClients;
  final bool canSetTxPower;

  /// Can cut a single device's internet access.
  final bool canBlockDevices;

  /// Router reports per-device byte counters (for per-device usage).
  final bool perDeviceTraffic;
}

class RouterCredentials {
  const RouterCredentials({
    required this.gatewayIp,
    required this.username,
    required this.password,
    this.useHttps = false,
  });

  final String gatewayIp;
  final String username;
  final String password;
  final bool useHttps;

  String get baseUrl => '${useHttps ? 'https' : 'http'}://$gatewayIp';
}

class RouterStatus {
  const RouterStatus({
    required this.connected,
    required this.model,
    required this.gatewayIp,
    this.firmwareVersion,
    this.wanIp,
    this.wanType,
    this.lineStatus,
    this.dslDownstreamKbps,
    this.dslUpstreamKbps,
    this.uptime,
  });

  /// Internet (WAN) is up.
  final bool connected;
  final String model;
  final String gatewayIp;
  final String? firmwareVersion;
  final String? wanIp;

  /// e.g. "VDSL2 / PTM", "ADSL2+ / ATM", "Ethernet WAN".
  final String? wanType;

  /// e.g. "Up", "Training", "NoSignal".
  final String? lineStatus;
  final int? dslDownstreamKbps;
  final int? dslUpstreamKbps;
  final Duration? uptime;
}

/// Raw cumulative counters as reported by the router's WAN interface.
/// They reset to zero when the router reboots (and may wrap at 2^32 on
/// some firmwares) — [UsageCalculatorService] takes care of that.
class TrafficCounters {
  const TrafficCounters({
    required this.rxBytes,
    required this.txBytes,
    required this.timestamp,
  });

  final int rxBytes;
  final int txBytes;
  final DateTime timestamp;
}

class SpeedLimit {
  const SpeedLimit._(this.mbps);
  const SpeedLimit.unlimited() : mbps = null;
  factory SpeedLimit.mbps(double value) {
    assert(value > 0);
    return SpeedLimit._(value);
  }

  /// `null` means unlimited.
  final double? mbps;
  bool get isUnlimited => mbps == null;
  int? get kbps => mbps == null ? null : (mbps! * 1000).round();

  @override
  bool operator ==(Object other) => other is SpeedLimit && other.mbps == mbps;
  @override
  int get hashCode => mbps.hashCode;
}

class SpeedLimitResult {
  const SpeedLimitResult({
    required this.success,
    required this.method,
    required this.limit,
    this.message,
  });

  final bool success;
  final SpeedLimitMethod method;
  final SpeedLimit limit;
  final String? message;
}

class ConnectedDevice {
  const ConnectedDevice({
    required this.name,
    required this.ip,
    required this.mac,
    required this.band,
    this.signalDbm,
    this.signalLevel,
    this.active = true,
    this.blocked = false,
    this.downloadedBytes,
    this.uploadedBytes,
    this.vendor,
  });

  final String name;
  final String ip;
  final String mac;
  final WifiBand band;

  /// Signal in dBm when the router reports it (negative number).
  final int? signalDbm;

  /// Signal as 0-5 bars (what ZYXEL reports).
  final int? signalLevel;
  final bool active;

  /// Internet access cut by the app / router.
  final bool blocked;

  /// Cumulative counters as seen by the router (reset when the device
  /// reconnects or the router reboots). Router→device = downloaded.
  final int? downloadedBytes;
  final int? uploadedBytes;
  final String? vendor;
}

class WifiSettings {
  const WifiSettings({
    required this.ssid,
    required this.password,
    this.enabled = true,
    this.maxClients = 32,
    this.txPowerPercent = 100,
    this.hidden = false,
  });

  final String ssid;
  final String password;
  final bool enabled;

  /// Max associated stations (per radio).
  final int maxClients;

  /// Transmit power, 0-100 %.
  final int txPowerPercent;
  final bool hidden;

  WifiSettings copyWith({
    String? ssid,
    String? password,
    bool? enabled,
    int? maxClients,
    int? txPowerPercent,
    bool? hidden,
  }) =>
      WifiSettings(
        ssid: ssid ?? this.ssid,
        password: password ?? this.password,
        enabled: enabled ?? this.enabled,
        maxClients: maxClients ?? this.maxClients,
        txPowerPercent: txPowerPercent ?? this.txPowerPercent,
        hidden: hidden ?? this.hidden,
      );
}

class DnsSettings {
  const DnsSettings({this.primary, this.secondary});
  final String? primary;
  final String? secondary;

  DnsPreset get preset => DnsPreset.match(primary);
  factory DnsSettings.fromPreset(DnsPreset p) =>
      DnsSettings(primary: p.primary, secondary: p.secondary);
}

/// Errors surfaced to the UI with a stable [code] so they can be localized.
class RouterException implements Exception {
  const RouterException(this.code, [this.details]);

  final RouterErrorCode code;
  final String? details;

  @override
  String toString() => 'RouterException(${code.name}${details == null ? '' : ': $details'})';
}

enum RouterErrorCode {
  unreachable,
  notOnLan,
  invalidCredentials,
  sessionExpired,
  tooManySessions,
  lockedOut,
  unsupportedFirmware,
  notSupported,
  unexpectedResponse,
}
