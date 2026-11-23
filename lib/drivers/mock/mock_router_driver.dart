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

    _rx += downMbps * 1e6 / 8 * secs;
    _tx += upMbps * 1e6 / 8 * secs;
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
    int sig(int base) => base - _random.nextInt(6);
    return [
      ConnectedDevice(name: 'Galaxy S25', ip: '192.168.1.34', mac: 'A4:C3:F0:12:9B:01', band: WifiBand.band5, signalDbm: sig(-48)),
      ConnectedDevice(name: 'iPhone-Mona', ip: '192.168.1.35', mac: 'F0:99:B6:7A:44:2C', band: WifiBand.band5, signalDbm: sig(-55)),
      ConnectedDevice(name: 'Living-Room-TV', ip: '192.168.1.40', mac: '7C:1C:68:AA:10:3E', band: WifiBand.band24, signalDbm: sig(-63)),
      const ConnectedDevice(name: 'Desktop-PC', ip: '192.168.1.10', mac: '00:1B:21:3C:8D:50', band: WifiBand.ethernet),
      ConnectedDevice(name: 'Laptop-Work', ip: '192.168.1.22', mac: '3C:22:FB:91:0E:77', band: WifiBand.band5, signalDbm: sig(-58)),
      ConnectedDevice(name: 'ESP32-Plug', ip: '192.168.1.51', mac: '24:6F:28:00:AB:CD', band: WifiBand.band24, signalDbm: sig(-72)),
      ConnectedDevice(name: 'Tablet-Kids', ip: '192.168.1.37', mac: '58:CB:52:19:E2:61', band: WifiBand.band24, signalDbm: sig(-66), active: _random.nextBool()),
    ];
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
      _bootTime = _clock();
      _lastTick = _clock();
      _rebooting = false;
    });
  }
}
