import 'package:flutter_localizations/flutter_localizations.dart' show GlobalWidgetsLocalizations;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import 'core/l10n/app_strings.dart';
import 'core/notifications/usage_alerts.dart';
import 'core/state/app_state.dart';
import 'features/usage/presentation/usage_controller.dart';
import 'core/theme/app_theme.dart';
import 'features/setup/setup_screen.dart';
import 'features/shell/home_shell.dart';

class NetPulseApp extends ConsumerWidget {
  const NetPulseApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(appSettingsProvider);
    return MaterialApp(
      title: 'NetPulse Router Manager',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: settings.themeMode,
      locale: settings.locale,
      supportedLocales: AppStrings.supportedLocales,
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ],
      home: const _Gate(),
    );
  }
}

/// Decides between the setup screen and the main shell, and hands usage
/// counting over to the background worker while the app is not visible.
class _Gate extends ConsumerStatefulWidget {
  const _Gate();

  @override
  ConsumerState<_Gate> createState() => _GateState();
}

class _GateState extends ConsumerState<_Gate> {
  late final AppLifecycleListener _lifecycle;
  bool _askedNotifications = false;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(
      onPause: () => ref.read(liveProvider.notifier).pause(),
      onResume: () async {
        // The background isolate may have updated the ledger meanwhile.
        await ref.read(sharedPrefsProvider).reload();
        ref.invalidate(usageControllerProvider);
        ref.read(liveProvider.notifier).resume();
      },
    );
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final boot = ref.watch(bootstrapProvider);
    final session = ref.watch(sessionProvider);
    if (boot.isLoading && !session.isConnected) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (session.isConnected && !_askedNotifications) {
      _askedNotifications = true;
      UsageAlerts.requestPermission();
    }
    return session.isConnected ? const HomeShell() : const SetupScreen();
  }
}
