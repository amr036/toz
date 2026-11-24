import 'dart:async';
import 'dart:math';

import '../router_driver.dart';

/// Fully simulated router used for demo mode / cloud preview / UI tests.
///
/// * Counters grow over time at a realistic, noisy rate.
/// * The applied speed limit actually caps the simulated throughput, so the
///   dashboard's live rate visibly reacts when you apply 2 / 6 / 10 Mbps.
/// * [rebootRouter] resets counters to zero, exercising the usage
///   calculator's reboot-reset handling.
class MockRouterDriver extends RouterDriver {
  MockRouterDriver(super.credentials, {Random? random, DateTime Function()? clock})
      : _random = random ?? Random(),
        _clock = clock ?? DateTime.now {
    _bootTime = _clock().subtract(const Duration(days: 3, hours: 7, minutes: 12));
    _lastTick = _clock();
  }

  /// Username/password accepted by the simulator.
  static const demoUsername = 'admin';
  static const demoPassword = 'demo';

  /// MAC → (name, share of traffic); also used to seed demo history.
  static const demoDeviceShares = <String, (String, double)>{
    'A4:C3:F0:12:9B:01': ('Galaxy S25', 0.30),
    'F0:99:B6:7A:44:2C': ('iPhone-Mona', 0.18),
    '7C:1C:68:AA:10:3E': ('Living-Room-TV', 0.32),
    '00:1B:21:3C:8D:50': ('Desktop-PC', 0.12),
    '3C:22:FB:91:0E:77': ('Laptop-Work', 0.06),
    '24:6F:28:00:AB:CD': ('ESP32-Plug', 0.005),
    '58:CB:52:19:E2:61': ('Tablet-Kids', 0.015),
  };

  final Random _random;
  final DateTime Function() _clock;

  bool _loggedIn = false;
  late DateTime _bootTime;
  late DateTime _lastTick;
  bool _rebooting = false;

  // Counters start "mid-session" so the dashboard looks alive immediately.
  double _rx = 18.4 * 1024 * 1024 * 1024;
  double _tx = 1.9 * 1024 * 1024 * 1024;

  SpeedLimit _limit = const SpeedLimit.unlimited();

  final _devices = <_MockDevice>[
    _MockDevice('Galaxy S25', '192.168.1.34', 'A4:C3:F0:12:9B:01', WifiBand.band5, 5, share: 0.30),
    _MockDevice('iPhone-Mona', '192.168.1.35', 'F0:99:B6:7A:44:2C', WifiBand.band5, 4, share: 0.18),
    _MockDevice('Living-Room-TV', '192.168.1.40', '7C:1C:68:AA:10:3E', WifiBand.band24, 3, share: 0.32),
    _MockDevice('Desktop-PC', '192.168.1.10', '00:1B:21:3C:8D:50', WifiBand.ethernet, 0, share: 0.12),
    _MockDevice('Laptop-Work', '192.168.1.22', '3C:22:FB:91:0E:77', WifiBand.band5, 4, share: 0.06),
    _MockDevice('ESP32-Plug', '192.168.1.51', '24:6F:28:00:AB:CD', WifiBand.band24, 2, share: 0.005),
    _MockDevice('Tablet-Kids', '192.168.1.37', '58:CB:52:19:E2:61', WifiBand.band24, 3, share: 0.015),
  ];
  WifiSettings _wifi = const WifiSettings(
    ssid: 'NetPulse_Home_5G',
    password: 'P@ssw0rd2026',
    maxClients: 24,
    txPowerPercent: 80,
  );
  DnsSettings _dns = const DnsSettings();

  static const _lineDownKbps = 51200;
  static const _lineUpKbps = 10240;

  @override
  String get modelName => 'ZYXEL VMG3625-T50B (Demo)';

  @override
  RouterCapabilities get capabilities =>
      const RouterCapabilities(speedLimitMethod: SpeedLimitMethod.qosShaper);

  @override
  bool get isLoggedIn => _loggedIn;

  Future<void> _latency() =>
      Future<void>.delayed(Duration(milliseconds: 150 + _random.nextInt(250)));

  void _ensure() {
    if (_rebooting) throw const RouterException(RouterErrorCode.unreachable, 'Router is rebooting');
    if (!_loggedIn) throw const RouterException(RouterErrorCode.sessionExpired);
  }

  /// Advances the simulated counters up to "now".
  void _tick() {
    final now = _clock();
    final secs = now.difference(_lastTick).inMilliseconds / 1000.0;
    _lastTick = now;
    if (secs <= 0) return;

    // Base demand: a household streaming + browsing, with random bursts.
    final hour = now.hour;
    final evening = hour >= 18 && hour <= 23;
    var downMbps = (evening ? 9.0 : 4.0) + _random.nextDouble() * 8;
    if (_random.nextDouble() < 0.08) downMbps += 20; // download burst
    var upMbps = 0.4 + _random.nextDouble() * 1.4;

    final cap = _limit.mbps;
    final lineDown = _lineDownKbps / 1000 * 0.92;
    final lineUp = _lineUpKbps / 1000 * 0.92;
    downMbps = min(downMbps, cap ?? lineDown);
    upMbps = min(upMbps, cap ?? lineUp);
    if (cap != null) {
      // Shaped traffic hugs the ceiling.
      downMbps = cap * (0.86 + _random.nextDouble() * 0.12);
      upMbps = min(upMbps, cap * 0.6);
    }

    // Blocked devices get no internet: their share is simply not used.
    final online = _devices.where((d) => d.active && !d.blocked);
    final totalShare = online.fold<double>(0, (a, d) => a + d.share);
    final blockedShare = _devices.where((d) => d.blocked).fold<double>(0, (a, d) => a + d.share);
    final factor = 1 - blockedShare.clamp(0.0, 0.9);
    final dDown = downMbps * factor * 1e6 / 8 * secs;
    final dUp = upMbps * factor * 1e6 / 8 * secs;
    _rx += dDown;
    _tx += dUp;
    for (final d in online) {
      d.down += dDown * d.share / totalShare;
      d.up += dUp * d.share / totalShare;
    }
  }

  @override
  Future<void> login() async {
    await _latency();
    if (_rebooting) throw const RouterException(RouterErrorCode.unreachable);
    if (credentials.username != demoUsername || credentials.password != demoPassword) {
      throw const RouterException(RouterErrorCode.invalidCredentials);
    }
    _loggedIn = true;
  }

  @override
  Future<void> logout() async {
    _loggedIn = false;
  }

  @override
  Future<RouterStatus> getRouterStatus() async {
    await _latency();
    _ensure();
    return RouterStatus(
      connected: true,
      model: modelName,
      gatewayIp: credentials.gatewayIp,
      firmwareVersion: 'V5.50(ABPM.9)C0 (simulated)',
      wanIp: '41.235.18.77',
      wanType: 'VDSL2 / PTM',
      lineStatus: 'Up',
      dslDownstreamKbps: _lineDownKbps,
      dslUpstreamKbps: _lineUpKbps,
      uptime: _clock().difference(_bootTime),
    );
  }

  @override
  Future<TrafficCounters> getTrafficCounters() async {
    await _latency();
    _ensure();
    _tick();
    return TrafficCounters(rxBytes: _rx.round(), txBytes: _tx.round(), timestamp: _clock());
  }

  @override
  Future<SpeedLimit> getWifiSpeedLimit() async {
    await _latency();
    _ensure();
    return _limit;
  }

  @override
  Future<SpeedLimitResult> setWifiSpeedLimit(SpeedLimit limit) async {
    await _latency();
    _ensure();
    _tick();
    _limit = limit;
    return SpeedLimitResult(
      success: true,
      method: capabilities.speedLimitMethod,
      limit: limit,
      message: limit.isUnlimited
          ? 'QoS shaper disabled (simulated)'
          : 'QoS shaper set to ${limit.kbps} kbps (simulated)',
    );
  }

  @override
  Future<List<ConnectedDevice>> getConnectedDevices() async {
    await _latency();
    _ensure();
    _tick();
    return [
      for (final d in _devices)
        ConnectedDevice(
          name: d.name,
          ip: d.ip,
          mac: d.mac,
          band: d.band,
          signalLevel: d.band == WifiBand.ethernet ? null : (d.level - _random.nextInt(2)).clamp(1, 5),
          active: d.active,
          blocked: d.blocked,
          downloadedBytes: d.down.round(),
          uploadedBytes: d.up.round(),
        ),
    ];
  }

  @override
  Future<void> setDeviceBlocked(String mac, bool blocked) async {
    await _latency();
    _ensure();
    _tick();
    _devices.firstWhere((d) => d.mac == mac.toUpperCase()).blocked = blocked;
  }

  @override
  Future<WifiSettings> getWifiSettings() async {
    await _latency();
    _ensure();
    return _wifi;
  }

  @override
  Future<void> updateWifiSettings(WifiSettings settings) async {
    await _latency();
    _ensure();
    if (settings.password.length < 8) {
      throw const RouterException(RouterErrorCode.unexpectedResponse, 'WPA2 password must be at least 8 characters');
    }
    _wifi = settings;
  }

  @override
  Future<DnsSettings> getDns() async {
    await _latency();
    _ensure();
    return _dns;
  }

  @override
  Future<void> setDns(DnsSettings dns) async {
    await _latency();
    _ensure();
    _dns = dns;
  }

  @override
  Future<void> rebootRouter() async {
    await _latency();
    _ensure();
    _rebooting = true;
    _loggedIn = false;
    // Simulate ~8 s outage, then counters start from zero.
    Timer(const Duration(seconds: 8), () {
      _rx = 0;
      _tx = 0;
      for (final d in _devices) {
        d.down = 0;
        d.up = 0;
      }
      _bootTime = _clock();
      _lastTick = _clock();
      _rebooting = false;
    });
  }
}

class _MockDevice {
  _MockDevice(this.name, this.ip, this.mac, this.band, this.level, {required this.share});
  final String name;
  final String ip;
  final String mac;
  final WifiBand band;
  final int level;
  final double share;
  bool active = true;
  bool blocked = false;
  double down = 0;
  double up = 0;
}
