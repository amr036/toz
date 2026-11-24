import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:workmanager/workmanager.dart';

import '../../drivers/driver_registry.dart';
import '../../drivers/router_models.dart';
import '../../features/devices/device_usage_controller.dart';
import '../../features/devices/domain/device_usage.dart';
import '../../features/usage/data/usage_repository.dart';
import '../../features/usage/domain/usage_calculator_service.dart';
import '../config/app_config.dart';
import '../notifications/usage_alerts.dart';
import '../storage/secure_credentials_store.dart';

/// Keeps counting usage while the app is closed (Android WorkManager,
/// roughly every 15 minutes — the OS minimum — when on a network).
///
/// Without it, traffic between the app's last poll and a router reboot would
/// be lost. Each run: login → read WAN counters → logout → update ledger →
/// quota alert if a threshold was crossed.
class BackgroundSync {
  static const taskName = 'netpulse.usageSync';
  static const _uniqueName = 'netpulse-usage-sync';

  /// SharedPreferences key the foreground app refreshes while it is polling.
  static const foregroundHeartbeatKey = 'fg.heartbeat';

  static bool get supported => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  static Future<void> register() async {
    if (!supported) return;
    await Workmanager().initialize(backgroundSyncDispatcher);
    await Workmanager().registerPeriodicTask(
      _uniqueName,
      taskName,
      frequency: const Duration(minutes: 15),
      constraints: Constraints(networkType: NetworkType.connected),
      existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
    );
  }

  /// One background sync. Public for testing / manual triggering.
  static Future<bool> run() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload(); // pick up what the UI isolate wrote

    // Demo mode has nothing real to count.
    if (prefs.getBool('demoMode') ?? AppConfig.demoModeDefault) return true;

    // The app is open and polling: let it own the ledger.
    final hb = prefs.getInt(foregroundHeartbeatKey);
    if (hb != null &&
        DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(hb)) < const Duration(minutes: 2)) {
      return true;
    }

    final creds = await SecureCredentialsStore().read();
    if (creds == null) return true;

    final model = RouterModelId.values.firstWhere(
      (m) => m.name == prefs.getString('routerModel'),
      orElse: () => RouterModelId.zyxelVmg3625T50b,
    );
    final driver = createDriver(model: model, credentials: creds, demoMode: false);
    try {
      await driver.login();
      final counters = await driver.getTrafficCounters();
      List<ConnectedDevice>? devices;
      try {
        devices = await driver.getConnectedDevices();
      } catch (_) {}
      await driver.logout();

      if (devices != null) {
        final devRepo = DeviceLedgerRepository(prefs, demo: false);
        final devLedger = devRepo.load();
        DeviceUsageService().ingest(devLedger, devices, DateTime.now());
        await devRepo.save(devLedger);
      }

      final repo = UsageRepository(prefs, demo: false);
      final svc = UsageCalculatorService();
      final ledger = repo.loadLedger();
      svc.ingest(ledger, counters);
      await repo.saveLedger(ledger);
      await UsageAlerts.check(prefs, svc.stats(ledger, repo.loadQuota(), DateTime.now()), demo: false);
      return true;
    } catch (e) {
      // Not on the home network, router down, …: not a failure worth retrying.
      debugPrint('[BackgroundSync] skipped: $e');
      return true;
    } finally {
      driver.dispose();
    }
  }
}

@pragma('vm:entry-point')
void backgroundSyncDispatcher() {
  Workmanager().executeTask((task, _) => BackgroundSync.run());
}
