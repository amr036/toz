import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../domain/usage_models.dart';

/// Persists the usage ledger + quota settings locally (SharedPreferences).
/// Demo mode uses a separate namespace so simulated traffic never pollutes
/// your real history.
class UsageRepository {
  UsageRepository(this._prefs, {required bool demo}) : _ns = demo ? 'demo.' : 'real.';

  final SharedPreferences _prefs;
  final String _ns;

  String get _ledgerKey => '${_ns}usage_ledger_v1';
  String get _quotaKey => '${_ns}quota_settings_v1';

  UsageLedger loadLedger() {
    final raw = _prefs.getString(_ledgerKey);
    if (raw == null) return UsageLedger();
    try {
      return UsageLedger.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return UsageLedger();
    }
  }

  Future<void> saveLedger(UsageLedger ledger) =>
      _prefs.setString(_ledgerKey, jsonEncode(ledger.toJson()));

  QuotaSettings loadQuota() {
    final raw = _prefs.getString(_quotaKey);
    if (raw == null) return const QuotaSettings();
    try {
      return QuotaSettings.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return const QuotaSettings();
    }
  }

  Future<void> saveQuota(QuotaSettings q) => _prefs.setString(_quotaKey, jsonEncode(q.toJson()));

  Future<void> resetLedger() => _prefs.remove(_ledgerKey);
}
