import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../features/setup/setup_screen.dart';
import '../l10n/app_strings.dart';
import '../state/app_state.dart';
import 'common.dart';

/// Shared app bar: title, demo badge, language + theme toggles, settings.
class AppTopBar extends ConsumerWidget implements PreferredSizeWidget {
  const AppTopBar({super.key, required this.title});
  final String title;

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(appSettingsProvider);
    return AppBar(
      title: Row(mainAxisSize: MainAxisSize.min, children: [
        Flexible(child: Text(title, overflow: TextOverflow.ellipsis)),
        if (settings.demoMode) ...[const SizedBox(width: 8), const DemoBadge()],
      ]),
      actions: [
        IconButton(
          tooltip: context.tr('language'),
          icon: const Icon(Icons.translate),
          onPressed: () => ref.read(appSettingsProvider.notifier).toggleLocale(),
        ),
        IconButton(
          icon: Icon(settings.themeMode == ThemeMode.dark ? Icons.light_mode_outlined : Icons.dark_mode_outlined),
          onPressed: () => ref.read(appSettingsProvider.notifier).toggleTheme(),
        ),
        IconButton(
          tooltip: context.tr('routerSettings'),
          icon: const Icon(Icons.settings_outlined),
          onPressed: () => Navigator.of(context)
              .push(MaterialPageRoute<void>(builder: (_) => const SetupScreen(pushed: true))),
        ),
      ],
    );
  }
}
