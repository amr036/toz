import 'package:flutter_localizations/flutter_localizations.dart' show GlobalWidgetsLocalizations;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import 'core/l10n/app_strings.dart';
import 'core/state/app_state.dart';
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

/// Decides between the setup screen and the main shell.
class _Gate extends ConsumerWidget {
  const _Gate();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final boot = ref.watch(bootstrapProvider);
    final session = ref.watch(sessionProvider);
    if (boot.isLoading && !session.isConnected) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return session.isConnected ? const HomeShell() : const SetupScreen();
  }
}
