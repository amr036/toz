import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/l10n/app_strings.dart';
import '../../core/state/app_state.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/app_top_bar.dart';
import '../../core/widgets/common.dart';
import '../../drivers/router_driver.dart';

final devicesProvider = FutureProvider<List<ConnectedDevice>>((ref) {
  final d = ref.watch(sessionProvider.select((s) => s.driver));
  if (d == null) throw const RouterException(RouterErrorCode.sessionExpired);
  return d.getConnectedDevices();
});

class DevicesScreen extends ConsumerWidget {
  const DevicesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(devicesProvider);
    return Scaffold(
      appBar: AppTopBar(title: context.tr('devicesTitle')),
      body: RefreshIndicator(
        onRefresh: () => ref.refresh(devicesProvider.future).catchError((_) => <ConnectedDevice>[]),
        child: async.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => ListView(padding: const EdgeInsets.all(16), children: [
            ErrorBanner(message: errorText(context, e), onRetry: () => ref.invalidate(devicesProvider)),
          ]),
          data: (devices) {
            if (devices.isEmpty) {
              return ListView(children: [
                const SizedBox(height: 120),
                Center(child: Text(context.tr('noDevices'))),
              ]);
            }
            final sorted = [...devices]..sort((a, b) {
                if (a.active != b.active) return a.active ? -1 : 1;
                return a.name.toLowerCase().compareTo(b.name.toLowerCase());
              });
            final counts = <WifiBand, int>{};
            for (final d in devices.where((d) => d.active)) {
              counts[d.band] = (counts[d.band] ?? 0) + 1;
            }
            return ListView(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
              children: [
                Wrap(spacing: 8, runSpacing: 8, children: [
                  Chip(
                    avatar: const Icon(Icons.devices, size: 18),
                    label: Text('${devices.where((d) => d.active).length} ${context.tr('online')}'),
                  ),
                  for (final e in counts.entries)
                    Chip(
                      avatar: Icon(_bandIcon(e.key), size: 18),
                      label: Text('${context.tr('band_${e.key.name}')}: ${e.value}'),
                    ),
                ]),
                const SizedBox(height: 12),
                for (final d in sorted) ...[
                  _DeviceTile(device: d),
                  const SizedBox(height: 8),
                ],
              ],
            );
          },
        ),
      ),
    );
  }
}

IconData _bandIcon(WifiBand b) => switch (b) {
      WifiBand.band24 => Icons.wifi,
      WifiBand.band5 => Icons.wifi_tethering,
      WifiBand.ethernet => Icons.settings_ethernet,
      WifiBand.unknown => Icons.device_unknown,
    };

class _DeviceTile extends StatelessWidget {
  const _DeviceTile({required this.device});
  final ConnectedDevice device;

  Color _signalColor(int? dbm) {
    if (dbm == null) return AppColors.upload;
    if (dbm >= -60) return AppColors.download;
    if (dbm >= -70) return AppColors.warning;
    return AppColors.danger;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final d = device;
    final mono = TextStyle(fontFamily: 'monospace', fontSize: 12, color: scheme.onSurfaceVariant);
    return Opacity(
      opacity: d.active ? 1 : 0.5,
      child: Card(
        child: ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          leading: CircleAvatar(
            backgroundColor: _signalColor(d.signalDbm).withValues(alpha: 0.16),
            child: Icon(_bandIcon(d.band), color: _signalColor(d.signalDbm)),
          ),
          title: Text(d.name, style: const TextStyle(fontWeight: FontWeight.w700)),
          subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(d.ip, style: mono, textDirection: TextDirection.ltr),
            Text(d.mac, style: mono, textDirection: TextDirection.ltr),
          ]),
          trailing: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(context.tr('band_${d.band.name}'), style: const TextStyle(fontWeight: FontWeight.w600)),
              if (!d.active)
                Text(context.tr('inactive'), style: TextStyle(fontSize: 12, color: scheme.error))
              else if (d.signalDbm != null)
                Text('${d.signalDbm} dBm',
                    textDirection: TextDirection.ltr,
                    style: TextStyle(fontSize: 12, color: _signalColor(d.signalDbm))),
            ],
          ),
        ),
      ),
    );
  }
}
