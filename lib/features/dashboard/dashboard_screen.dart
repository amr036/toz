import 'package:fl_chart/fl_chart.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart' hide TextDirection;
import 'package:material_ui/material_ui.dart';

import '../../core/l10n/app_strings.dart';
import '../../core/state/app_state.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/formatters.dart';
import '../../core/widgets/app_top_bar.dart';
import '../../core/widgets/common.dart';
import '../admin/router_admin_screen.dart';
import '../shell/home_shell.dart';
import '../usage/presentation/usage_controller.dart';

class DashboardScreen extends ConsumerWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final live = ref.watch(liveProvider);
    return Scaffold(
      appBar: AppTopBar(title: context.tr('appName')),
      body: RefreshIndicator(
        onRefresh: () => ref.read(liveProvider.notifier).refresh(forceStatus: true),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
          children: [
            if (live.error != null) ...[
              ErrorBanner(
                message: errorText(context, live.error),
                onRetry: () => ref.read(liveProvider.notifier).refresh(forceStatus: true),
              ),
              const SizedBox(height: 12),
            ],
            const _StatusHeader(),
            const SizedBox(height: 12),
            const _LiveRateCard(),
            const SizedBox(height: 12),
            const _CycleMiniCard(),
            SectionTitle(context.tr('quickActions')),
            const _QuickActions(),
          ],
        ),
      ),
    );
  }
}

class _StatusHeader extends ConsumerWidget {
  const _StatusHeader();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final live = ref.watch(liveProvider);
    final driver = ref.watch(sessionProvider.select((s) => s.driver));
    final st = live.status;
    final scheme = Theme.of(context).colorScheme;
    final online = st?.connected ?? false;
    final statusColor = st == null ? scheme.outline : (online ? AppColors.download : AppColors.danger);

    Widget row(IconData icon, String label, String value, {bool ltrValue = true}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: Row(children: [
            Icon(icon, size: 18, color: scheme.onSurfaceVariant),
            const SizedBox(width: 10),
            Text(label, style: TextStyle(color: scheme.onSurfaceVariant)),
            const Spacer(),
            Flexible(
              child: Text(value,
                  textDirection: ltrValue ? TextDirection.ltr : null,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w600)),
            ),
          ]),
        );

    return Card(
      clipBehavior: Clip.antiAlias,
      child: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: AlignmentDirectional.topStart,
            end: AlignmentDirectional.bottomEnd,
            colors: [scheme.primary.withValues(alpha: 0.22), scheme.surfaceContainerHigh],
          ),
        ),
        padding: const EdgeInsets.all(18),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: scheme.primary.withValues(alpha: 0.18), shape: BoxShape.circle),
              child: Icon(Icons.router, color: scheme.primary, size: 28),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(st?.model ?? driver?.modelName ?? '—',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
                const SizedBox(height: 4),
                Row(children: [
                  Container(
                      width: 9,
                      height: 9,
                      decoration: BoxDecoration(color: statusColor, shape: BoxShape.circle)),
                  const SizedBox(width: 6),
                  Text(
                    '${context.tr('internet')}: ${st == null ? '…' : context.tr(online ? 'connected' : 'disconnected')}',
                    style: TextStyle(color: statusColor, fontWeight: FontWeight.w600),
                  ),
                ]),
              ]),
            ),
            if (live.loading) const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
          ]),
          const SizedBox(height: 14),
          row(Icons.lan_outlined, context.tr('gatewayIp'), driver?.credentials.gatewayIp ?? '—'),
          row(Icons.public, context.tr('wanIp'), st?.wanIp ?? '—'),
          row(Icons.cable, context.tr('line'), [st?.wanType, st?.lineStatus].whereType<String>().where((s) => s.isNotEmpty).join(' · ').ifEmpty('—')),
          row(Icons.swap_vert, context.tr('lineSync'),
              '↓${formatKbpsLine(st?.dslDownstreamKbps)} / ↑${formatKbpsLine(st?.dslUpstreamKbps)} Mbps'),
          row(Icons.timer_outlined, context.tr('uptime'), formatUptime(st?.uptime, arabic: context.isArabic),
              ltrValue: false),
          if (st?.firmwareVersion != null) row(Icons.system_update_alt, context.tr('firmware'), st!.firmwareVersion!),
        ]),
      ),
    );
  }
}

extension on String {
  String ifEmpty(String fallback) => isEmpty ? fallback : this;
}

class _LiveRateCard extends ConsumerWidget {
  const _LiveRateCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final live = ref.watch(liveProvider);
    final scheme = Theme.of(context).colorScheme;

    Widget rate(IconData icon, String label, double bps, Color c) => Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Icon(icon, color: c, size: 18),
              const SizedBox(width: 4),
              Text(label, style: TextStyle(color: scheme.onSurfaceVariant)),
            ]),
            const SizedBox(height: 4),
            Text(formatRate(bps),
                textDirection: TextDirection.ltr,
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800, color: c)),
          ]),
        );

    List<FlSpot> spots(List<double> l) =>
        [for (var i = 0; i < l.length; i++) FlSpot(i.toDouble(), l[i] / 1e6)];

    LineChartBarData line(List<double> l, Color c) => LineChartBarData(
          spots: spots(l),
          isCurved: true,
          preventCurveOverShooting: true,
          color: c,
          barWidth: 2.5,
          dotData: const FlDotData(show: false),
          belowBarData: BarAreaData(show: true, color: c.withValues(alpha: 0.12)),
        );

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(context.tr('liveRate'), style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 10),
          Row(children: [
            rate(Icons.south_rounded, context.tr('download'), live.downBps, AppColors.download),
            rate(Icons.north_rounded, context.tr('upload'), live.upBps, AppColors.upload),
          ]),
          const SizedBox(height: 14),
          SizedBox(
            height: 90,
            child: live.downHistory.length < 2
                ? const Center(child: LinearProgressIndicator())
                : LineChart(
                    LineChartData(
                      minY: 0,
                      gridData: const FlGridData(show: false),
                      borderData: FlBorderData(show: false),
                      titlesData: const FlTitlesData(show: false),
                      lineTouchData: const LineTouchData(enabled: false),
                      lineBarsData: [
                        line(live.downHistory, AppColors.download),
                        line(live.upHistory, AppColors.upload),
                      ],
                    ),
                    duration: const Duration(milliseconds: 250),
                  ),
          ),
          if (live.updatedAt != null) ...[
            const SizedBox(height: 8),
            Text(
              '${context.tr('lastUpdated')}: ${DateFormat.Hms().format(live.updatedAt!)}',
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
            ),
          ],
        ]),
      ),
    );
  }
}

class _CycleMiniCard extends ConsumerWidget {
  const _CycleMiniCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final usage = ref.watch(usageControllerProvider);
    final s = usage.stats;
    final scheme = Theme.of(context).colorScheme;
    final pct = (s.percent / 100).clamp(0.0, 1.0);
    final color = s.percent >= 90
        ? AppColors.danger
        : s.percent >= 75
            ? AppColors.warning
            : scheme.primary;
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: () => ref.read(homeTabProvider.notifier).select(1),
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Text(context.tr('cycleUsage'), style: Theme.of(context).textTheme.titleSmall),
              const Spacer(),
              Text('${s.percent.toStringAsFixed(1)}%',
                  style: TextStyle(fontWeight: FontWeight.w800, color: color)),
              const Icon(Icons.chevron_right),
            ]),
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: LinearProgressIndicator(value: pct, minHeight: 10, color: color),
            ),
            const SizedBox(height: 10),
            Text(
              '${formatGb(s.usedBytes)} / ${gbLabel(s.quotaBytes, decimals: 0)}  ·  '
              '${context.tr('remaining')} ${gbLabel(s.remainingBytes)}',
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
          ]),
        ),
      ),
    );
  }
}

class _QuickActions extends ConsumerWidget {
  const _QuickActions();

  Future<void> _reboot(BuildContext context, WidgetRef ref) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.restart_alt),
        title: Text(ctx.tr('reboot')),
        content: Text(ctx.tr('rebootConfirm')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(ctx.tr('cancel'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(ctx.tr('reboot'))),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    try {
      await requireDriver(ref).rebootRouter();
      if (context.mounted) showSnack(context, context.tr('rebooting'));
    } catch (e) {
      if (context.mounted) showSnack(context, errorText(context, e), error: true);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    Widget action(IconData icon, String label, Color color, VoidCallback onTap) => Expanded(
          child: Card(
            child: InkWell(
              borderRadius: BorderRadius.circular(20),
              onTap: onTap,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 8),
                child: Column(children: [
                  CircleAvatar(
                    radius: 24,
                    backgroundColor: color.withValues(alpha: 0.16),
                    child: Icon(icon, color: color),
                  ),
                  const SizedBox(height: 10),
                  Text(label, textAlign: TextAlign.center, maxLines: 2, style: const TextStyle(fontSize: 13)),
                ]),
              ),
            ),
          ),
        );

    return Row(children: [
      action(Icons.restart_alt, context.tr('reboot'), AppColors.danger, () => _reboot(context, ref)),
      const SizedBox(width: 10),
      action(Icons.admin_panel_settings_outlined, context.tr('openAdmin'), AppColors.upload, () {
        Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const RouterAdminScreen()));
      }),
      const SizedBox(width: 10),
      action(Icons.sync, context.tr('syncNow'), AppColors.download, () async {
        await ref.read(liveProvider.notifier).refresh(forceStatus: true);
        if (context.mounted) showSnack(context, context.tr('synced'));
      }),
    ]);
  }
}
