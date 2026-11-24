import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app.dart';
import 'core/background/background_sync.dart';
import 'core/notifications/usage_alerts.dart';
import 'core/state/app_state.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();
  // Android-only extras; never block startup on them.
  try {
    await UsageAlerts.init();
    await BackgroundSync.register();
  } catch (e) {
    debugPrint('Background setup failed: $e');
  }
  runApp(ProviderScope(
    // Router errors are surfaced to the user; don't silently auto-retry.
    retry: (_, _) => null,
    overrides: [sharedPrefsProvider.overrideWithValue(prefs)],
    child: const NetPulseApp(),
  ));
}
