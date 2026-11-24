import 'dart:math';

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart' hide TextDirection;
import 'package:material_ui/material_ui.dart';

import '../../../core/config/app_config.dart';
import '../../../core/l10n/app_strings.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/widgets/app_top_bar.dart';
import '../../../core/widgets/common.dart';
import '../domain/usage_models.dart';
import '../../../core/state/app_state.dart';
import 'usage_controller.dart';

class UsageScreen extends ConsumerWidget {
  const UsageScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final usage = ref.watch(usageControllerProvider);
    final s = usage.stats;
    return Scaffold(
      appBar: AppTopBar(title: context.tr('usageTitle')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
        children: [
          _WarningBanner(stats: s),
          _GaugeCard(state: usage),
          const SizedBox(height: 12),
          _StatsGrid(state: usage),
          if (s.projectedToExceed && s.warning != UsageWarning.p100) ...[
            const SizedBox(height: 12),
            Card(
              color: AppColors.warning.withValues(alpha: 0.15),
              child: ListTile(
                leading: const Icon(Icons.trending_up, color: AppColors.warning),
                title: Text(context.tr('willExceed')),
              ),
            ),
          ],
          SectionTitle(context.tr('history')),
          const _HistoryChart(),
          SectionTitle(context.tr('quotaSettings')),
          _QuotaSettingsCard(quota: usage.quota),
          const SizedBox(height: 12),
          const _RouterCounterCard(),
          const SizedBox(height: 12),
          _CalibrationCard(state: usage),
          const SizedBox(height: 12),
          Center(
            child: TextButton.icon(
              icon: const Icon(Icons.delete_outline),
              label: Text(context.tr('resetHistory')),
              onPressed: () async {
                final ok = await showDialog<bool>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    content: Text(ctx.tr('resetHistoryConfirm')),
                    actions: [
                      TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(ctx.tr('cancel'))),
                      FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(ctx.tr('ok'))),
                    ],
                  ),
                );
                if (ok == true) await ref.read(usageControllerProvider.notifier).resetHistory();
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _WarningBanner extends StatelessWidget {
  const _WarningBanner({required this.stats});
  final UsageStats stats;

  @override
  Widget build(BuildContext context) {
    final (key, color, icon) = switch (stats.warning) {
      UsageWarning.none => (null, null, null),
      UsageWarning.p75 => ('warn75', AppColors.warning, Icons.info_outline),
      UsageWarning.p90 => ('warn90', AppColors.danger, Icons.warning_amber_rounded),
      UsageWarning.p100 => ('warn100', AppColors.danger, Icons.block),
    };
    if (key == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Card(
        color: color!.withValues(alpha: 0.18),
        child: ListTile(
          leading: Icon(icon, color: color),
          title: Text(context.tr(key), style: const TextStyle(fontWeight: FontWeight.w600)),
        ),
      ),
    );
  }
}

class _GaugeCard extends StatelessWidget {
  const _GaugeCard({required this.state});
  final UsageState state;

  @override
  Widget build(BuildContext context) {
    final s = state.stats;
    final scheme = Theme.of(context).colorScheme;
    final color = switch (s.warning) {
      UsageWarning.none => scheme.primary,
      UsageWarning.p75 => AppColors.warning,
      _ => AppColors.danger,
    };
    final df = DateFormat.MMMd(Localizations.localeOf(context).languageCode);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(children: [
          Text(
            '${context.tr('cycle')}: ${df.format(s.cycle.start)} → ${df.format(s.cycle.end)}',
            style: TextStyle(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: 220,
            height: 220,
            child: TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: (s.percent / 100).clamp(0.0, 1.0)),
              duration: const Duration(milliseconds: 900),
              curve: Curves.easeOutCubic,
              builder: (context, v, _) => CustomPaint(
                painter: _GaugePainter(
                  value: v,
                  color: color,
                  track: scheme.surfaceContainerHighest,
                  timeFraction: (s.daysElapsed / max(1, s.cycle.lengthDays)).clamp(0.0, 1.0),
                  marker: scheme.onSurfaceVariant,
                ),
                child: Center(
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Text('${s.percent.toStringAsFixed(1)}%',
                        style: Theme.of(context)
                            .textTheme
                            .displaySmall
                            ?.copyWith(fontWeight: FontWeight.w800, color: color)),
                    Text(gbLabel(s.usedBytes),
                        textDirection: TextDirection.ltr,
                        style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                    Text('${context.tr('of')} ${gbLabel(s.quotaBytes, decimals: 0)}',
                        style: TextStyle(color: scheme.onSurfaceVariant)),
                  ]),
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Row(mainAxisAlignment: MainAxisAlignment.spaceAround, children: [
            _kv(context, context.tr('used'), gbLabel(s.usedBytes), color),
            _kv(context, context.tr('remaining'), gbLabel(s.remainingBytes), AppColors.download),
          ]),
        ]),
      ),
    );
  }

  Widget _kv(BuildContext context, String k, String v, Color c) => Column(children: [
        Text(v,
            textDirection: TextDirection.ltr,
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: c)),
        Text(k, style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
      ]);
}

/// 270° gauge; the small tick shows how far through the billing cycle we are,
/// so "ahead of pace" is visible at a glance.
class _GaugePainter extends CustomPainter {
  _GaugePainter({
    required this.value,
    required this.color,
    required this.track,
    required this.timeFraction,
    required this.marker,
  });

  final double value;
  final Color color;
  final Color track;
  final double timeFraction;
  final Color marker;

  static const _start = 135 * pi / 180;
  static const _sweep = 270 * pi / 180;

  @override
  void paint(Canvas canvas, Size size) {
    const stroke = 18.0;
    final rect = Offset.zero & size;
    final arcRect = rect.deflate(stroke / 2 + 4);
    final base = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round;

    canvas.drawArc(arcRect, _start, _sweep, false, base..color = track);
    if (value > 0) {
      canvas.drawArc(
        arcRect,
        _start,
        _sweep * value,
        false,
        base
          ..shader = SweepGradient(
            startAngle: _start,
            endAngle: _start + _sweep,
            colors: [color.withValues(alpha: 0.55), color],
            transform: const GradientRotation(0),
          ).createShader(arcRect),
      );
    }

    // Time-in-cycle marker.
    final a = _start + _sweep * timeFraction;
    final r = arcRect.width / 2;
    final c = arcRect.center;
    final p1 = c + Offset(cos(a), sin(a)) * (r - stroke / 2 - 4);
    final p2 = c + Offset(cos(a), sin(a)) * (r + stroke / 2 + 2);
    canvas.drawLine(
      p1,
      p2,
      Paint()
        ..color = marker
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(_GaugePainter old) =>
      old.value != value || old.color != color || old.timeFraction != timeFraction;
}

class _StatsGrid extends StatelessWidget {
  const _StatsGrid({required this.state});
  final UsageState state;

  @override
  Widget build(BuildContext context) {
    final s = state.stats;
    final days = context.tr('days');
    final exhausted = s.daysUntilExhausted;
    final tiles = [
      StatTile(
          icon: Icons.calendar_view_day,
          label: context.tr('dailyAvg'),
          value: '${gbLabel(s.dailyAverageBytes, decimals: 2)}${context.tr('perDay')}'),
      StatTile(
          icon: Icons.insights,
          label: context.tr('projected'),
          value: gbLabel(s.projectedCycleBytes),
          color: s.projectedToExceed ? AppColors.danger : AppColors.download),
      StatTile(
          icon: Icons.hourglass_bottom,
          label: context.tr('daysLeftQuota'),
          value: exhausted == null ? context.tr('never') : '${exhausted.toStringAsFixed(1)} $days',
          color: exhausted != null && exhausted < s.daysLeftInCycle ? AppColors.danger : null),
      StatTile(
          icon: Icons.event_repeat,
          label: context.tr('daysLeftCycle'),
          value: '${s.daysLeftInCycle.toStringAsFixed(1)} $days'),
      StatTile(
          icon: Icons.savings_outlined,
          label: context.tr('dailyBudget'),
          value: '${gbLabel(s.dailyBudgetBytes, decimals: 2)}${context.tr('perDay')}'),
      StatTile(
          icon: Icons.restart_alt,
          label: context.tr('resetsDetected'),
          value: '${state.ledger.resetCount}'),
    ];
    return LayoutBuilder(builder: (context, c) {
      final cols = c.maxWidth > 600 ? 3 : 2;
      const gap = 10.0;
      final w = (c.maxWidth - gap * (cols - 1)) / cols;
      return Wrap(
        spacing: gap,
        runSpacing: gap,
        children: [for (final t in tiles) SizedBox(width: w, child: t)],
      );
    });
  }
}

class _HistoryChart extends ConsumerStatefulWidget {
  const _HistoryChart();

  @override
  ConsumerState<_HistoryChart> createState() => _HistoryChartState();
}

class _HistoryChartState extends ConsumerState<_HistoryChart> {
  int _days = 7;

  @override
  Widget build(BuildContext context) {
    final usage = ref.watch(usageControllerProvider);
    final points = ref.read(usageControllerProvider.notifier).series(_days);
    final countUp = usage.quota.countUpload;
    final budget = bytesToGb(usage.stats.dailyBudgetBytes);
    final scheme = Theme.of(context).colorScheme;
    final maxGb = points.fold<double>(budget, (m, p) => max(m, bytesToGb(p.total(countUp))));
    final lang = Localizations.localeOf(context).languageCode;

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 16, 16, 12),
        child: Column(children: [
          SegmentedButton<int>(
            segments: [
              ButtonSegment(value: 7, label: Text(context.tr('last7'))),
              ButtonSegment(value: 30, label: Text(context.tr('last30'))),
            ],
            selected: {_days},
            onSelectionChanged: (s) => setState(() => _days = s.first),
          ),
          const SizedBox(height: 16),
          SizedBox(
            height: 200,
            child: Directionality(
              // Charts read left→right (oldest → today) in both languages.
              textDirection: TextDirection.ltr,
              child: BarChart(
                BarChartData(
                  maxY: maxGb * 1.15 + 0.1,
                  gridData: FlGridData(
                    drawVerticalLine: false,
                    getDrawingHorizontalLine: (_) =>
                        FlLine(color: scheme.outlineVariant.withValues(alpha: 0.4), strokeWidth: 1),
                  ),
                  borderData: FlBorderData(show: false),
                  extraLinesData: ExtraLinesData(horizontalLines: [
                    HorizontalLine(
                      y: budget,
                      color: AppColors.warning,
                      strokeWidth: 1.5,
                      dashArray: [6, 4],
                    ),
                  ]),
                  titlesData: FlTitlesData(
                    topTitles: const AxisTitles(),
                    rightTitles: const AxisTitles(),
                    leftTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        reservedSize: 34,
                        getTitlesWidget: (v, meta) => SideTitleWidget(
                          meta: meta,
                          child: Text(v.toStringAsFixed(0), style: const TextStyle(fontSize: 10)),
                        ),
                      ),
                    ),
                    bottomTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        reservedSize: 22,
                        getTitlesWidget: (v, meta) {
                          final i = v.toInt();
                          if (i < 0 || i >= points.length) return const SizedBox.shrink();
                          final step = _days == 7 ? 1 : 5;
                          if ((points.length - 1 - i) % step != 0) return const SizedBox.shrink();
                          final d = points[i].day;
                          return SideTitleWidget(
                            meta: meta,
                            child: Text(
                              _days == 7 ? DateFormat.E(lang).format(d) : '${d.day}/${d.month}',
                              style: const TextStyle(fontSize: 10),
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                  barTouchData: BarTouchData(
                    touchTooltipData: BarTouchTooltipData(
                      getTooltipItem: (group, _, rod, _) => BarTooltipItem(
                        '${DateFormat.MMMd(lang).format(points[group.x].day)}\n${rod.toY.toStringAsFixed(2)} GB',
                        const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                  ),
                  barGroups: [
                    for (var i = 0; i < points.length; i++)
                      BarChartGroupData(x: i, barRods: [
                        BarChartRodData(
                          toY: bytesToGb(points[i].total(countUp)),
                          width: _days == 7 ? 22 : 7,
                          borderRadius: BorderRadius.circular(4),
                          color: bytesToGb(points[i].total(countUp)) > budget
                              ? AppColors.warning
                              : scheme.primary,
                        ),
                      ]),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            Container(width: 14, height: 2, color: AppColors.warning),
            const SizedBox(width: 6),
            Text('${context.tr('dailyBudget')}: ${budget.toStringAsFixed(2)} GB',
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
          ]),
        ]),
      ),
    );
  }
}

class _QuotaSettingsCard extends ConsumerWidget {
  const _QuotaSettingsCard({required this.quota});
  final QuotaSettings quota;

  Future<void> _custom(BuildContext context, WidgetRef ref) async {
    final ctrl = TextEditingController(text: quota.quotaGb.toStringAsFixed(0));
    final v = await showDialog<double>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(ctx.tr('customGb')),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
          decoration: const InputDecoration(suffixText: 'GB'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(ctx.tr('cancel'))),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, double.tryParse(ctrl.text)),
            child: Text(ctx.tr('save')),
          ),
        ],
      ),
    );
    if (v != null && v > 0) {
      await ref.read(usageControllerProvider.notifier).setQuota(quota.copyWith(quotaGb: v));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ctrl = ref.read(usageControllerProvider.notifier);
    final isPreset = AppConfig.quotaPresetsGb.contains(quota.quotaGb);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(context.tr('monthlyQuota'), style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: 10),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final gb in AppConfig.quotaPresetsGb)
              ChoiceChip(
                label: Text(gb >= 1000 ? '${(gb / 1000).toStringAsFixed(0)} TB' : '${gb.toInt()} GB'),
                selected: quota.quotaGb == gb,
                onSelected: (_) => ctrl.setQuota(quota.copyWith(quotaGb: gb)),
              ),
            ChoiceChip(
              avatar: const Icon(Icons.edit, size: 16),
              label: Text(isPreset ? context.tr('custom') : '${quota.quotaGb.toStringAsFixed(0)} GB'),
              selected: !isPreset,
              onSelected: (_) => _custom(context, ref),
            ),
          ]),
          const SizedBox(height: 16),
          Row(children: [
            Expanded(child: Text(context.tr('renewalDay'))),
            DropdownButton<int>(
              value: quota.renewalDay,
              menuMaxHeight: 320,
              items: [for (var d = 1; d <= 31; d++) DropdownMenuItem(value: d, child: Text('$d'))],
              onChanged: (d) {
                if (d != null) ctrl.setQuota(quota.copyWith(renewalDay: d));
              },
            ),
          ]),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(context.tr('countUpload')),
            value: quota.countUpload,
            onChanged: (v) => ctrl.setQuota(quota.copyWith(countUpload: v)),
          ),
        ]),
      ),
    );
  }
}

class _CalibrationCard extends ConsumerWidget {
  const _CalibrationCard({required this.state});
  final UsageState state;

  Future<void> _calibrate(BuildContext context, WidgetRef ref) async {
    final ctrl = TextEditingController(text: formatGb(state.stats.usedBytes, decimals: 2));
    final v = await showDialog<double>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.tune),
        title: Text(ctx.tr('calibrate')),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(ctx.tr('calibrateHint')),
          const SizedBox(height: 16),
          TextField(
            controller: ctrl,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
            decoration: InputDecoration(labelText: ctx.tr('usedGbIsp'), suffixText: 'GB'),
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(ctx.tr('cancel'))),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, double.tryParse(ctrl.text)),
            child: Text(ctx.tr('save')),
          ),
        ],
      ),
    );
    if (v != null && v >= 0) {
      await ref.read(usageControllerProvider.notifier).calibrate(v);
      if (context.mounted) showSnack(context, context.tr('calibrated'));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Card(
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        leading: const Icon(Icons.tune),
        title: Text(context.tr('calibrate')),
        subtitle: Text(
          state.isManualCalibration
              ? '${context.tr('calibrated')} (${state.ledger.calibrationAdjustBytes >= 0 ? '+' : ''}'
                  '${gbLabel(state.ledger.calibrationAdjustBytes, decimals: 2)})'
              : context.tr('calibrateHint'),
          style: const TextStyle(fontSize: 12),
        ),
        trailing: state.isManualCalibration
            ? IconButton(
                tooltip: context.tr('clearCalibration'),
                icon: const Icon(Icons.close),
                onPressed: () => ref.read(usageControllerProvider.notifier).clearCalibration(),
              )
            : const Icon(Icons.chevron_right),
        onTap: () => _calibrate(context, ref),
      ),
    );
  }
}

/// Shows the router's own counter since its last boot and whether the cycle
/// total was corrected from it automatically.
class _RouterCounterCard extends ConsumerWidget {
  const _RouterCounterCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final live = ref.watch(liveProvider);
    final usage = ref.watch(usageControllerProvider);
    final scheme = Theme.of(context).colorScheme;
    final c = live.counters;
    final uptime = live.status?.uptime;
    if (c == null) return const SizedBox.shrink();
    final routerBytes = c.rxBytes + (usage.quota.countUpload ? c.txBytes : 0);
    final boot = uptime == null ? null : DateTime.now().subtract(uptime);
    final bootInCycle = boot != null && !boot.isBefore(usage.stats.cycle.start);
    final auto = usage.isCalibrated && !usage.isManualCalibration;
    final lang = Localizations.localeOf(context).languageCode;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(Icons.router_outlined, color: scheme.primary),
            const SizedBox(width: 10),
            Expanded(child: Text(context.tr('routerCounter'), style: Theme.of(context).textTheme.titleSmall)),
            Text(gbLabel(routerBytes, decimals: 2), style: const TextStyle(fontWeight: FontWeight.w800)),
          ]),
          const SizedBox(height: 6),
          if (boot != null)
            Text(
              '${context.tr('sinceBoot')} ${DateFormat.MMMd(lang).add_Hm().format(boot)}',
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
            ),
          const SizedBox(height: 6),
          Text(
            context.tr(!bootInCycle ? 'routerCounterOldBoot' : (auto ? 'routerCounterApplied' : 'routerCounterMatches')),
            style: TextStyle(fontSize: 12, color: auto ? AppColors.download : scheme.onSurfaceVariant),
          ),
        ]),
      ),
    );
  }
}
