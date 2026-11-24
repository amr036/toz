import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/l10n/app_strings.dart';
import '../../core/network/local_network.dart';
import '../../core/state/app_state.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/formatters.dart';
import '../../core/widgets/app_top_bar.dart';
import '../../core/widgets/common.dart';
import '../../drivers/router_driver.dart';
import '../usage/presentation/usage_controller.dart';
import 'device_usage_controller.dart';
import 'domain/device_usage.dart';

/// First load of the device list (later refreshes come from live polling).
final devicesProvider = FutureProvider<List<ConnectedDevice>>((ref) async {
  final d = ref.watch(sessionProvider.select((s) => s.driver));
  if (d == null) throw const RouterException(RouterErrorCode.sessionExpired);
  final list = await d.getConnectedDevices();
  ref.read(deviceUsageProvider.notifier).ingest(list);
  return list;
});

/// This phone's own LAN IP (to recognise "this phone" in the list).
final phoneIpProvider = FutureProvider<String?>((ref) async {
  final gw = ref.watch(sessionProvider.select((s) => s.driver?.credentials.gatewayIp));
  return (await localNetworkInfo(gatewayIp: gw)).phoneIp;
});

/// Rough device type from the DHCP vendor class, for unnamed devices.
String? vendorHint(String? vendor) {
  final v = (vendor ?? '').toLowerCase();
  if (v.isEmpty) return null;
  if (v.contains('android')) return 'Android';
  if (v.contains('msft')) return 'Windows';
  if (v.contains('apple') || v.contains('iphone') || v.contains('ipad')) return 'Apple';
  if (v.contains('udhcp') || v.contains('esp') || v.contains('tuya')) return 'IoT';
  if (v.contains('dhcpcd') || v.contains('linux')) return 'Linux';
  return vendor;
}

/// A row = a device the router lists now, or one with usage this cycle that
/// is currently offline.
class _Row {
  _Row(this.mac, this.device, this.usage);
  final String mac;
  final ConnectedDevice? device;
  final DeviceCycleUsage? usage;

  String get name => usage?.track.displayName ?? device?.name ?? mac;
  bool get online => device?.active ?? false;
  bool get blocked => device?.blocked ?? false;
  int get cycleBytes => usage?.cycleBytes ?? 0;
}

class DevicesScreen extends ConsumerWidget {
  const DevicesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final first = ref.watch(devicesProvider);
    final liveDevices = ref.watch(liveProvider.select((l) => l.devices));
    final usage = ref.watch(deviceUsageProvider);
    final devices = liveDevices ?? first.value;

    Future<void> refresh() async {
      await ref.read(liveProvider.notifier).refreshDevices();
      if (liveDevices == null) ref.invalidate(devicesProvider);
    }

    Widget body;
    if (devices == null && first.isLoading) {
      body = const Center(child: CircularProgressIndicator());
    } else if (devices == null && first.hasError) {
      body = ListView(padding: const EdgeInsets.all(16), children: [
        ErrorBanner(message: errorText(context, first.error), onRetry: () => ref.invalidate(devicesProvider)),
      ]);
    } else {
      final byMac = {for (final d in devices ?? const <ConnectedDevice>[]) d.mac.toUpperCase(): d};
      final rows = <_Row>[
        for (final d in byMac.values) _Row(d.mac.toUpperCase(), d, usage.of(d.mac)),
        for (final u in usage.rows)
          if (!byMac.containsKey(u.track.mac) && u.cycleBytes > 0) _Row(u.track.mac, null, u),
      ]..sort((a, b) {
          if (a.online != b.online) return a.online ? -1 : 1;
          return b.cycleBytes.compareTo(a.cycleBytes);
        });
      body = ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
        children: [
          _UsageSummary(rows: rows),
          const SizedBox(height: 12),
          if (rows.isEmpty)
            Padding(padding: const EdgeInsets.all(40), child: Center(child: Text(context.tr('noDevices'))))
          else
            for (final r in rows) ...[
              _DeviceTile(row: r),
              const SizedBox(height: 8),
            ],
          Text(context.tr('deviceUsageNote'),
              style: TextStyle(fontSize: 11, color: Theme.of(context).colorScheme.onSurfaceVariant)),
        ],
      );
    }

    return Scaffold(
      appBar: AppTopBar(title: context.tr('devicesTitle')),
      body: RefreshIndicator(onRefresh: refresh, child: body),
    );
  }
}

class _UsageSummary extends ConsumerWidget {
  const _UsageSummary({required this.rows});
  final List<_Row> rows;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final quota = ref.watch(usageControllerProvider.select((u) => u.quota));
    final online = rows.where((r) => r.online).length;
    final blocked = rows.where((r) => r.blocked).length;
    final top = [...rows]..sort((a, b) => b.cycleBytes.compareTo(a.cycleBytes));
    final topUsers = top.where((r) => r.cycleBytes > 0).take(3).toList();
    final colors = [scheme.primary, AppColors.upload, AppColors.warning];

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Wrap(spacing: 8, runSpacing: 8, children: [
            Chip(avatar: const Icon(Icons.devices, size: 18), label: Text('$online ${context.tr('online')}')),
            if (blocked > 0)
              Chip(
                avatar: const Icon(Icons.block, size: 18, color: AppColors.danger),
                label: Text('$blocked ${context.tr('blockedCount')}'),
              ),
          ]),
          if (topUsers.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(context.tr('topUsers'), style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            for (var i = 0; i < topUsers.length; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Expanded(
                      child: Text(topUsers[i].name,
                          maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
                    ),
                    Text(
                      '${gbLabel(topUsers[i].cycleBytes)} · '
                      '${ltr('${((topUsers[i].usage?.shareOfQuota ?? 0) * 100).toStringAsFixed(1)}%')}',
                    ),
                  ]),
                  const SizedBox(height: 4),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: LinearProgressIndicator(
                      minHeight: 7,
                      color: colors[i],
                      value: ((topUsers[i].usage?.shareOfQuota ?? 0)).clamp(0.0, 1.0),
                    ),
                  ),
                ]),
              ),
            Text(
              '${context.tr('of')} ${gbLabel(quota.quotaBytes, decimals: 0)}',
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
            ),
          ],
        ]),
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

Color _signalColor(ConnectedDevice? d) {
  final lvl = d?.signalLevel;
  final dbm = d?.signalDbm;
  if (lvl != null) return lvl >= 4 ? AppColors.download : (lvl >= 2 ? AppColors.warning : AppColors.danger);
  if (dbm != null) return dbm >= -60 ? AppColors.download : (dbm >= -70 ? AppColors.warning : AppColors.danger);
  return AppColors.upload;
}

class _SignalBars extends StatelessWidget {
  const _SignalBars(this.level, this.color);
  final int level;
  final Color color;

  @override
  Widget build(BuildContext context) => Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          for (var i = 1; i <= 5; i++)
            Container(
              width: 4,
              height: 4.0 + i * 2.5,
              margin: const EdgeInsets.symmetric(horizontal: 1),
              decoration: BoxDecoration(
                color: i <= level ? color : Theme.of(context).colorScheme.outlineVariant,
                borderRadius: BorderRadius.circular(1),
              ),
            ),
        ],
      );
}

class _DeviceTile extends ConsumerWidget {
  const _DeviceTile({required this.row});
  final _Row row;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final d = row.device;
    final u = row.usage;
    final mono = TextStyle(fontFamily: 'monospace', fontSize: 11, color: scheme.onSurfaceVariant);
    final color = row.blocked ? AppColors.danger : _signalColor(d);
    final phoneIp = ref.watch(phoneIpProvider).value;
    final isThisPhone = d != null && phoneIp != null && d.ip == phoneIp;
    final unnamed = row.name.toUpperCase() == row.mac;
    final hint = unnamed ? vendorHint(d?.vendor) : null;

    return Opacity(
      opacity: row.online || row.blocked ? 1 : 0.55,
      child: Card(
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: () => showModalBottomSheet<void>(
            context: context,
            isScrollControlled: true,
            showDragHandle: true,
            builder: (_) => _DeviceSheet(row: row),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
            child: Row(children: [
              CircleAvatar(
                backgroundColor: color.withValues(alpha: 0.16),
                child: Icon(row.blocked ? Icons.block : _bandIcon(d?.band ?? WifiBand.unknown), color: color),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Flexible(
                      child: Text(
                        unnamed ? (hint == null ? context.tr('unnamedDevice') : '${context.tr('unnamedDevice')} · $hint') : row.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          decoration: unnamed ? TextDecoration.underline : null,
                          decorationStyle: TextDecorationStyle.dotted,
                        ),
                      ),
                    ),
                    InkResponse(
                      radius: 18,
                      onTap: () => renameDevice(context, ref, row.mac, routerName: d?.name, vendor: d?.vendor),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        child: Icon(Icons.edit_outlined, size: 16, color: unnamed ? scheme.primary : scheme.onSurfaceVariant),
                      ),
                    ),
                    if (isThisPhone) ...[const SizedBox(width: 2), _Badge(context.tr('thisPhone'), AppColors.upload)],
                  ]),
                  const SizedBox(height: 2),
                  Text('${d?.ip ?? '—'}  ·  ${row.mac}', style: mono, textDirection: TextDirection.ltr),
                  const SizedBox(height: 6),
                  Wrap(spacing: 10, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
                    Text(
                      '${gbLabel(row.cycleBytes, decimals: 2)} ${context.tr('thisCycleShort')}',
                      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
                    ),
                    if (u != null)
                      Text(
                        '${ltr('${(u.shareOfQuota * 100).toStringAsFixed(1)}%')} ${context.tr('ofQuota')}',
                        style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                      ),
                    if (row.blocked)
                      _Badge(context.tr('blocked'), AppColors.danger)
                    else if (!row.online)
                      _Badge(context.tr('inactive'), scheme.outline)
                    else if (d != null && d.band != WifiBand.ethernet && d.signalLevel != null)
                      _SignalBars(d.signalLevel!, color)
                    else if (d != null)
                      Text(context.tr('band_${d.band.name}'), style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
                  ]),
                ]),
              ),
              if (d != null) _BlockSwitch(device: d, name: row.name),
            ]),
          ),
        ),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge(this.text, this.color);
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        decoration: BoxDecoration(color: color.withValues(alpha: 0.18), borderRadius: BorderRadius.circular(6)),
        child: Text(text, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: color)),
      );
}

/// Internet on/off for one device, with confirmation before cutting.
class _BlockSwitch extends ConsumerStatefulWidget {
  const _BlockSwitch({required this.device, required this.name});
  final ConnectedDevice device;
  final String name;

  @override
  ConsumerState<_BlockSwitch> createState() => _BlockSwitchState();
}

class _BlockSwitchState extends ConsumerState<_BlockSwitch> {
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final caps = ref.watch(sessionProvider.select((s) => s.driver?.capabilities));
    if (!(caps?.canBlockDevices ?? false)) return const SizedBox.shrink();
    if (_busy) {
      return const Padding(
        padding: EdgeInsets.all(14),
        child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5)),
      );
    }
    return Tooltip(
      message: context.tr('internetAccess'),
      child: Switch(
        value: !widget.device.blocked,
        activeTrackColor: AppColors.download,
        onChanged: (allow) => setDeviceBlocked(context, ref, widget.device, widget.name, !allow,
            onBusy: (b) => mounted ? setState(() => _busy = b) : null),
      ),
    );
  }
}

Future<void> setDeviceBlocked(
  BuildContext context,
  WidgetRef ref,
  ConnectedDevice device,
  String name,
  bool block, {
  void Function(bool busy)? onBusy,
}) async {
  if (block) {
    final phoneIp = (await localNetworkInfo(gatewayIp: requireDriver(ref).credentials.gatewayIp)).phoneIp;
    final self = phoneIp != null && phoneIp == device.ip;
    if (!context.mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.block, color: AppColors.danger),
        title: Text(ctx.tr('blockTitle')),
        content: Text('${ctx.tr(self ? 'blockSelfWarning' : 'blockConfirm')}\n\n$name\n${device.mac}'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(ctx.tr('cancel'))),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(ctx.tr('blockAction')),
          ),
        ],
      ),
    );
    if (ok != true) return;
  }
  onBusy?.call(true);
  try {
    await requireDriver(ref).setDeviceBlocked(device.mac, block);
    await ref.read(liveProvider.notifier).refreshDevices();
    if (context.mounted) showSnack(context, context.tr(block ? 'blockedDone' : 'unblockedDone'));
  } catch (e) {
    if (context.mounted) showSnack(context, errorText(context, e), error: true);
  } finally {
    onBusy?.call(false);
  }
}

class _DeviceSheet extends ConsumerWidget {
  const _DeviceSheet({required this.row});
  final _Row row;

  Future<void> _rename(BuildContext context, WidgetRef ref) =>
      renameDevice(context, ref, row.mac, routerName: row.device?.name, vendor: row.device?.vendor);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Re-read so the sheet reflects renames / blocking while open.
    final usage = ref.watch(deviceUsageProvider).of(row.mac);
    final device = ref.watch(liveProvider.select((l) => l.devices))?.where((d) => d.mac.toUpperCase() == row.mac).firstOrNull ??
        row.device;
    final scheme = Theme.of(context).colorScheme;
    final name = usage?.track.displayName ?? device?.name ?? row.mac;

    Widget kv(String k, String v) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(children: [
            Text(k, style: TextStyle(color: scheme.onSurfaceVariant)),
            const Spacer(),
            Text(v, textDirection: TextDirection.ltr, style: const TextStyle(fontWeight: FontWeight.w600)),
          ]),
        );

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(20, 0, 20, 20 + MediaQuery.of(context).viewInsets.bottom),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Expanded(
              child: Text(name,
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis),
            ),
            IconButton(
              tooltip: context.tr('renameDevice'),
              icon: const Icon(Icons.edit_outlined),
              onPressed: () => _rename(context, ref),
            ),
          ]),
          const SizedBox(height: 8),
          kv(context.tr('thisCycle'), gbLabel(usage?.cycleBytes ?? 0, decimals: 2)),
          kv(context.tr('ofQuotaLong'), ltr('${((usage?.shareOfQuota ?? 0) * 100).toStringAsFixed(1)}%')),
          kv(context.tr('shareOfDevices'), ltr('${((usage?.shareOfDevices ?? 0) * 100).toStringAsFixed(1)}%')),
          kv(context.tr('today'), gbLabel(usage?.todayBytes ?? 0, decimals: 2)),
          const Divider(height: 24),
          kv('IP', device?.ip ?? '—'),
          kv('MAC', row.mac),
          if (device != null) kv(context.tr('connection'), context.tr('band_${device.band.name}')),
          if (device?.signalLevel != null) kv(context.tr('signal'), '${device!.signalLevel}/5'),
          if (device?.signalDbm != null) kv(context.tr('signal'), '${device!.signalDbm} dBm'),
          const SizedBox(height: 16),
          if (device != null)
            device.blocked
                ? FilledButton.icon(
                    style: FilledButton.styleFrom(backgroundColor: AppColors.download, foregroundColor: Colors.black),
                    onPressed: () => setDeviceBlocked(context, ref, device, name, false),
                    icon: const Icon(Icons.wifi),
                    label: Text(context.tr('unblockAction')),
                  )
                : FilledButton.icon(
                    style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
                    onPressed: () => setDeviceBlocked(context, ref, device, name, true),
                    icon: const Icon(Icons.block),
                    label: Text(context.tr('blockAction')),
                  ),
        ]),
      ),
    );
  }
}

/// Lets the user give a device a name (stored on this phone, per MAC).
/// Offers the router's own name and common device types as one-tap picks.
Future<void> renameDevice(
  BuildContext context,
  WidgetRef ref,
  String mac, {
  String? routerName,
  String? vendor,
}) async {
  final current = ref.read(deviceUsageProvider).of(mac)?.track.nickname ??
      ref.read(deviceUsageProvider).ledger.devices[mac.toUpperCase()]?.nickname;
  final ctrl = TextEditingController(text: current ?? '');
  final picks = <String>[
    if (routerName != null && routerName.toUpperCase() != mac.toUpperCase()) routerName,
    for (final k in const ['pickPhone', 'pickLaptop', 'pickTv', 'pickTablet', 'pickPc', 'pickConsole', 'pickCamera'])
      context.tr(k),
  ];
  final hint = vendorHint(vendor);

  final v = await showDialog<String>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => AlertDialog(
        icon: const Icon(Icons.edit_outlined),
        title: Text(ctx.tr('renameDevice')),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(mac, textDirection: TextDirection.ltr, style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
            if (hint != null) Text('${ctx.tr('deviceType')}: $hint', style: const TextStyle(fontSize: 12)),
            const SizedBox(height: 12),
            TextField(
              controller: ctrl,
              autofocus: true,
              maxLength: 32,
              textInputAction: TextInputAction.done,
              onSubmitted: (t) => Navigator.pop(ctx, t),
              decoration: InputDecoration(
                hintText: ctx.tr('renameHint'),
                suffixIcon: ctrl.text.isEmpty
                    ? null
                    : IconButton(icon: const Icon(Icons.clear), onPressed: () => setState(ctrl.clear)),
              ),
              onChanged: (_) => setState(() {}),
            ),
            Wrap(spacing: 6, runSpacing: 6, children: [
              for (final p in picks)
                ActionChip(
                  label: Text(p),
                  onPressed: () => setState(() {
                    // Types are a prefix: "موبايل " → "موبايل أحمد".
                    final isRouterName = p == routerName;
                    ctrl.text = isRouterName ? p : '$p ';
                    ctrl.selection = TextSelection.collapsed(offset: ctrl.text.length);
                  }),
                ),
            ]),
          ]),
        ),
        actions: [
          if (current != null)
            TextButton(onPressed: () => Navigator.pop(ctx, ''), child: Text(ctx.tr('removeName'))),
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(ctx.tr('cancel'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text), child: Text(ctx.tr('save'))),
        ],
      ),
    ),
  );
  if (v == null) return;
  await ref.read(deviceUsageProvider.notifier).rename(mac, v);
  if (context.mounted) showSnack(context, context.tr(v.trim().isEmpty ? 'nameRemoved' : 'nameSaved'));
}
