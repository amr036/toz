import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../drivers/router_models.dart';

/// Router credentials encrypted on-device (Android Keystore-backed).
/// They are only ever sent to the configured LAN gateway.
class SecureCredentialsStore {
  SecureCredentialsStore([FlutterSecureStorage? storage])
      : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  static const _kIp = 'router_gateway_ip';
  static const _kUser = 'router_username';
  static const _kPass = 'router_password';
  static const _kHttps = 'router_https';

  Future<RouterCredentials?> read() async {
    try {
      final ip = await _storage.read(key: _kIp);
      final user = await _storage.read(key: _kUser);
      final pass = await _storage.read(key: _kPass);
      if (ip == null || user == null || pass == null) return null;
      return RouterCredentials(
        gatewayIp: ip,
        username: user,
        password: pass,
        useHttps: await _storage.read(key: _kHttps) == 'true',
      );
    } catch (_) {
      // Keystore can be wiped (e.g. after restoring a backup) — treat as empty.
      return null;
    }
  }

  Future<void> write(RouterCredentials c) async {
    await _storage.write(key: _kIp, value: c.gatewayIp);
    await _storage.write(key: _kUser, value: c.username);
    await _storage.write(key: _kPass, value: c.password);
    await _storage.write(key: _kHttps, value: '${c.useHttps}');
  }

  Future<void> clear() async {
    for (final k in [_kIp, _kUser, _kPass, _kHttps]) {
      await _storage.delete(key: k);
    }
  }
}
