import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/l10n/app_strings.dart';
import '../dashboard/dashboard_screen.dart';
import '../devices/devices_screen.dart';
import '../usage/presentation/usage_screen.dart';
import '../wifi_control/wifi_control_screen.dart';

final homeTabProvider = NotifierProvider<_TabController, int>(_TabController.new);

class _TabController extends Notifier<int> {
  @override
  int build() => 0;
  void select(int i) => state = i;
}

class HomeShell extends ConsumerWidget {
  const HomeShell({super.key});

  static const _pages = [DashboardScreen(), UsageScreen(), WifiControlScreen(), DevicesScreen()];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final index = ref.watch(homeTabProvider);
    return Scaffold(
      body: IndexedStack(index: index, children: _pages),
      bottomNavigationBar: NavigationBar(
        selectedIndex: index,
        onDestinationSelected: ref.read(homeTabProvider.notifier).select,
        destinations: [
          NavigationDestination(
              icon: const Icon(Icons.speed_outlined),
              selectedIcon: const Icon(Icons.speed),
              label: context.tr('navDashboard')),
          NavigationDestination(
              icon: const Icon(Icons.data_usage_outlined),
              selectedIcon: const Icon(Icons.data_usage),
              label: context.tr('navUsage')),
          NavigationDestination(
              icon: const Icon(Icons.wifi_outlined),
              selectedIcon: const Icon(Icons.wifi),
              label: context.tr('navWifi')),
          NavigationDestination(
              icon: const Icon(Icons.devices_other_outlined),
              selectedIcon: const Icon(Icons.devices_other),
              label: context.tr('navDevices')),
        ],
      ),
    );
  }
}
