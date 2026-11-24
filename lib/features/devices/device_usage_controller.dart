import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/state/app_state.dart';
import '../../drivers/mock/mock_router_driver.dart';
import '../../drivers/router_models.dart';
import '../usage/presentation/usage_controller.dart';
import 'domain/device_usage.dart';

/// Local persistence for per-device usage (separate demo/real namespaces).
class DeviceLedgerRepository {
  DeviceLedgerRepository(this._prefs, {required bool demo}) : _key = '${demo ? 'demo' : 'real'}.device_ledger_v1';

  final SharedPreferences _prefs;
  final String _key;

  DeviceLedger load() {
    final raw = _prefs.getString(_key);
    if (raw == null) return DeviceLedger();
    try {
      return DeviceLedger.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return DeviceLedger();
    }
  }

  Future<void> save(DeviceLedger l) => _prefs.setString(_key, jsonEncode(l.toJson()));

  Future<void> clear() => _prefs.remove(_key);
}

class DeviceUsageState {
  const DeviceUsageState(this.ledger, this.rows);
  final DeviceLedger ledger;
  final List<DeviceCycleUsage> rows;

  DeviceCycleUsage? of(String mac) {
    final m = mac.toUpperCase();
    for (final r in rows) {
      if (r.track.mac == m) return r;
    }
    return null;
  }
}

class DeviceUsageController extends Notifier<DeviceUsageState> {
  late DeviceLedgerRepository _repo;
  final _svc = DeviceUsageService();

  @override
  DeviceUsageState build() {
    final demo = ref.watch(appSettingsProvider.select((s) => s.demoMode));
    final quota = ref.watch(usageControllerProvider.select((u) => u.quota));
    _repo = DeviceLedgerRepository(ref.watch(sharedPrefsProvider), demo: demo);
    final ledger = _repo.load();
    if (demo && ledger.devices.isEmpty) {
      DeviceUsageService.seedDemo(ledger, ref.read(usageControllerProvider).ledger, MockRouterDriver.demoDeviceShares);
      _repo.save(ledger);
    }
    return DeviceUsageState(ledger, _svc.cycleUsage(ledger, quota, DateTime.now()));
  }

  void _emit(DeviceLedger l) {
    final quota = ref.read(usageControllerProvider).quota;
    state = DeviceUsageState(l, _svc.cycleUsage(l, quota, DateTime.now()));
  }

  void ingest(List<ConnectedDevice> devices) {
    final l = state.ledger.clone();
    _svc.ingest(l, devices, DateTime.now());
    _repo.save(l);
    _emit(l);
  }

  Future<void> rename(String mac, String nickname) async {
    final l = state.ledger.clone();
    final t = l.devices.putIfAbsent(mac.toUpperCase(), () => DeviceTrack(mac: mac.toUpperCase()));
    t.nickname = nickname.trim().isEmpty ? null : nickname.trim();
    await _repo.save(l);
    _emit(l);
  }
}

final deviceUsageProvider = NotifierProvider<DeviceUsageController, DeviceUsageState>(DeviceUsageController.new);
