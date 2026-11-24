import 'router_models.dart';

export 'router_models.dart';

/// Contract every router integration implements.
///
/// The UI and services only talk to this interface, so adding a ZTE H188A or
/// Huawei HG633 driver means adding one class and registering it in
/// `driver_registry.dart` — nothing else changes.
///
/// All communication is LOCAL ONLY (LAN gateway). Drivers must never send
/// credentials or router data anywhere except [RouterCredentials.baseUrl].
abstract class RouterDriver {
  RouterDriver(this.credentials);

  final RouterCredentials credentials;

  /// Human readable model name, e.g. "ZYXEL VMG3625-T50B".
  String get modelName;

  RouterCapabilities get capabilities;

  bool get isLoggedIn;

  /// Establishes a session. Throws [RouterException] on failure.
  Future<void> login();

  Future<void> logout();

  Future<RouterStatus> getRouterStatus();

  /// Cumulative WAN RX/TX byte counters since the router's last boot.
  Future<TrafficCounters> getTrafficCounters();

  /// Currently active limit, if the firmware lets us read it back.
  Future<SpeedLimit> getWifiSpeedLimit();

  Future<SpeedLimitResult> setWifiSpeedLimit(SpeedLimit limit);

  Future<List<ConnectedDevice>> getConnectedDevices();

  Future<WifiSettings> getWifiSettings();

  Future<void> updateWifiSettings(WifiSettings settings);

  Future<DnsSettings> getDns();

  Future<void> setDns(DnsSettings dns);

  Future<void> rebootRouter();

  /// Cuts (or restores) internet access for one device, by MAC address.
  Future<void> setDeviceBlocked(String mac, bool blocked);

  /// URL of the router's own web admin UI (used by the WebView fallback).
  Uri get adminPageUri => Uri.parse(credentials.baseUrl);

  /// Release sockets / timers.
  void dispose() {}
}
