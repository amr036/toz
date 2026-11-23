import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../drivers/driver_registry.dart';
import '../../drivers/mock/mock_router_driver.dart';
import '../../drivers/router_driver.dart';
import '../../features/usage/domain/usage_calculator_service.dart';
import '../config/app_config.dart';
import '../storage/secure_credentials_store.dart';
import '../../features/usage/presentation/usage_controller.dart';

/// Overridden in main() with the loaded instance.
final sharedPrefsProvider = Provider<SharedPreferences>(
  (ref) => throw UnimplementedError('sharedPrefsProvider must be overridden'),
);

final secureStoreProvider = Provider<SecureCredentialsStore>((ref) => SecureCredentialsStore());

// -----------------------------------------------------------------------------
// App settings (non-secret, SharedPreferences)
// -----------------------------------------------------------------------------

class AppSettings {
  const AppSettings({
    required this.locale,
    required this.demoMode,
    required this.model,
    required this.themeMode,
  });

  final Locale locale;
  final bool demoMode;
  final RouterModelId model;
  final ThemeMode themeMode;

  AppSettings copyWith({Locale? locale, bool? demoMode, RouterModelId? model, ThemeMode? themeMode}) =>
      AppSettings(
        locale: locale ?? this.locale,
        demoMode: demoMode ?? this.demoMode,
        model: model ?? this.model,
        themeMode: themeMode ?? this.themeMode,
      );
}

class AppSettingsController extends Notifier<AppSettings> {
  SharedPreferences get _prefs => ref.read(sharedPrefsProvider);

  @override
  AppSettings build() {
    final p = ref.watch(sharedPrefsProvider);
    return AppSettings(
      locale: Locale(p.getString('locale') ?? 'ar'),
      demoMode: p.getBool('demoMode') ?? AppConfig.demoModeDefault,
      model: RouterModelId.values.firstWhere(
        (m) => m.name == p.getString('routerModel'),
        orElse: () => RouterModelId.zyxelVmg3625T50b,
      ),
      themeMode: p.getString('theme') == 'light' ? ThemeMode.light : ThemeMode.dark,
    );
  }

  void toggleLocale() {
    final next = state.locale.languageCode == 'ar' ? const Locale('en') : const Locale('ar');
    _prefs.setString('locale', next.languageCode);
    state = state.copyWith(locale: next);
  }

  void toggleTheme() {
    final next = state.themeMode == ThemeMode.dark ? ThemeMode.light : ThemeMode.dark;
    _prefs.setString('theme', next == ThemeMode.light ? 'light' : 'dark');
    state = state.copyWith(themeMode: next);
  }

  void setDemoMode(bool v) {
    _prefs.setBool('demoMode', v);
    state = state.copyWith(demoMode: v);
  }

  void setModel(RouterModelId m) {
    _prefs.setString('routerModel', m.name);
    state = state.copyWith(model: m);
  }
}

final appSettingsProvider =
    NotifierProvider<AppSettingsController, AppSettings>(AppSettingsController.new);

// -----------------------------------------------------------------------------
// Router session
// -----------------------------------------------------------------------------

enum SessionPhase { idle, connecting, connected, error }

class SessionState {
  const SessionState({this.phase = SessionPhase.idle, this.driver, this.error});

  final SessionPhase phase;
  final RouterDriver? driver;
  final Object? error;

  bool get isConnected => phase == SessionPhase.connected && driver != null;
}

class SessionController extends Notifier<SessionState> {
  @override
  SessionState build() {
    ref.onDispose(() => state.driver?.dispose());
    return const SessionState();
  }

  static const demoCredentials = RouterCredentials(
    gatewayIp: AppConfig.defaultGatewayIp,
    username: MockRouterDriver.demoUsername,
    password: MockRouterDriver.demoPassword,
  );

  /// Called once at startup: demo → connect immediately; real → use saved creds.
  Future<void> autoConnect() async {
    final settings = ref.read(appSettingsProvider);
    if (settings.demoMode) {
      await connect(demoCredentials, remember: false);
      return;
    }
    final saved = await ref.read(secureStoreProvider).read();
    if (saved != null) await connect(saved, remember: false);
  }

  Future<bool> connect(RouterCredentials creds, {bool remember = true}) async {
    final settings = ref.read(appSettingsProvider);
    state.driver?.dispose();
    state = const SessionState(phase: SessionPhase.connecting);
    try {
      final driver = createDriver(model: settings.model, credentials: creds, demoMode: settings.demoMode);
      await driver.login();
      if (remember && !settings.demoMode) await ref.read(secureStoreProvider).write(creds);
      state = SessionState(phase: SessionPhase.connected, driver: driver);
      return true;
    } catch (e) {
      state = SessionState(phase: SessionPhase.error, error: e);
      return false;
    }
  }

  Future<void> disconnect({bool forget = false}) async {
    final d = state.driver;
    state = const SessionState();
    if (d != null) {
      await d.logout();
      d.dispose();
    }
    if (forget) await ref.read(secureStoreProvider).clear();
  }
}

final sessionProvider = NotifierProvider<SessionController, SessionState>(SessionController.new);

final bootstrapProvider = FutureProvider<void>((ref) async {
  await ref.read(sessionProvider.notifier).autoConnect();
});

/// Convenience accessor for screens; throws if not connected.
RouterDriver requireDriver(WidgetRef ref) {
  final d = ref.read(sessionProvider).driver;
  if (d == null) throw const RouterException(RouterErrorCode.sessionExpired);
  return d;
}

// -----------------------------------------------------------------------------
// Live polling: status + counters → live rate + usage ledger
// -----------------------------------------------------------------------------

class LiveState {
  const LiveState({
    this.status,
    this.counters,
    this.downBps = 0,
    this.upBps = 0,
    this.downHistory = const [],
    this.upHistory = const [],
    this.updatedAt,
    this.error,
    this.loading = false,
  });

  final RouterStatus? status;
  final TrafficCounters? counters;
  final double downBps;
  final double upBps;

  /// Recent rate samples (bits/s) for sparklines.
  final List<double> downHistory;
  final List<double> upHistory;
  final DateTime? updatedAt;
  final Object? error;
  final bool loading;

  LiveState copyWith({
    RouterStatus? status,
    TrafficCounters? counters,
    double? downBps,
    double? upBps,
    List<double>? downHistory,
    List<double>? upHistory,
    DateTime? updatedAt,
    Object? error,
    bool clearError = false,
    bool? loading,
  }) =>
      LiveState(
        status: status ?? this.status,
        counters: counters ?? this.counters,
        downBps: downBps ?? this.downBps,
        upBps: upBps ?? this.upBps,
        downHistory: downHistory ?? this.downHistory,
        upHistory: upHistory ?? this.upHistory,
        updatedAt: updatedAt ?? this.updatedAt,
        error: clearError ? null : (error ?? this.error),
        loading: loading ?? this.loading,
      );
}

class LiveController extends Notifier<LiveState> {
  Timer? _timer;
  int _tick = 0;
  bool _busy = false;
  bool _paused = false;
  static const _historyLen = 40;

  @override
  LiveState build() {
    final driver = ref.watch(sessionProvider.select((s) => s.driver));
    final demo = ref.watch(appSettingsProvider.select((s) => s.demoMode));
    _timer?.cancel();
    _tick = 0;
    ref.onDispose(() => _timer?.cancel());
    if (driver != null) {
      final interval = demo ? AppConfig.demoPollInterval : AppConfig.routerPollInterval;
      _timer = Timer.periodic(interval, (_) => refresh());
      Future.microtask(() => refresh(forceStatus: true));
    }
    return const LiveState();
  }

  /// Stop polling while the app is in the background (the WorkManager job
  /// takes over counting), resume when it comes back.
  void pause() => _paused = true;

  void resume() {
    _paused = false;
    refresh(forceStatus: true);
  }

  Future<void> refresh({bool forceStatus = false}) async {
    final driver = ref.read(sessionProvider).driver;
    if (driver == null || _busy || _paused) return;
    _busy = true;
    if (forceStatus && ref.mounted) state = state.copyWith(loading: true);
    try {
      await _poll(driver, forceStatus || _tick % 3 == 0);
    } on RouterException catch (e) {
      if (e.code == RouterErrorCode.sessionExpired) {
        try {
          await driver.login();
        } catch (_) {/* reported on next tick */}
      }
      if (ref.mounted) state = state.copyWith(error: e, loading: false);
    } catch (e) {
      if (ref.mounted) state = state.copyWith(error: e, loading: false);
    } finally {
      _busy = false;
      _tick++;
    }
  }

  Future<void> _poll(RouterDriver driver, bool withStatus) async {
    // Status and counters are fetched independently: a firmware that names
    // one endpoint differently must not blank the whole dashboard.
    Object? statusError;
    if (withStatus || state.status == null) {
      try {
        final status = await driver.getRouterStatus();
        if (ref.mounted) state = state.copyWith(status: status);
      } on RouterException catch (e) {
        if (e.code == RouterErrorCode.sessionExpired || e.code == RouterErrorCode.unreachable) rethrow;
        statusError = e;
      }
    }
    final TrafficCounters counters;
    try {
      counters = await driver.getTrafficCounters();
    } on RouterException catch (e) {
      if (e.code == RouterErrorCode.sessionExpired || e.code == RouterErrorCode.unreachable) rethrow;
      if (ref.mounted) state = state.copyWith(error: e, loading: false, updatedAt: DateTime.now());
      return;
    }
    if (!ref.mounted) return;

    var down = state.downBps;
    var up = state.upBps;
    final prev = state.counters;
    if (prev != null) {
      final secs = counters.timestamp.difference(prev.timestamp).inMilliseconds / 1000.0;
      if (secs > 0.2) {
        final (dRx, _) = UsageCalculatorService.counterDelta(prev.rxBytes, counters.rxBytes);
        final (dTx, _) = UsageCalculatorService.counterDelta(prev.txBytes, counters.txBytes);
        down = dRx * 8 / secs;
        up = dTx * 8 / secs;
      }
    }

    List<double> push(List<double> l, double v) {
      final out = [...l, v];
      return out.length > _historyLen ? out.sublist(out.length - _historyLen) : out;
    }

    state = state.copyWith(
      counters: counters,
      downBps: down,
      upBps: up,
      downHistory: prev == null ? state.downHistory : push(state.downHistory, down),
      upHistory: prev == null ? state.upHistory : push(state.upHistory, up),
      updatedAt: DateTime.now(),
      error: statusError,
      clearError: statusError == null,
      loading: false,
    );
    ref.read(usageControllerProvider.notifier).ingest(counters);
  }
}

final liveProvider = NotifierProvider<LiveController, LiveState>(LiveController.new);
