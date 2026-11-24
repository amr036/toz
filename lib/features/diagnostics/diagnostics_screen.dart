import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/l10n/app_strings.dart';
import '../../core/state/app_state.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/common.dart';
import '../../drivers/driver_registry.dart';
import '../../drivers/router_models.dart';
import 'connection_diagnostics.dart';

/// "Test connection": runs [ConnectionDiagnostics] and shows each step, with a
/// copyable report for troubleshooting real hardware.
class DiagnosticsScreen extends ConsumerStatefulWidget {
  const DiagnosticsScreen({super.key, required this.credentials});

  final RouterCredentials credentials;

  @override
  ConsumerState<DiagnosticsScreen> createState() => _DiagnosticsScreenState();
}

class _DiagnosticsScreenState extends ConsumerState<DiagnosticsScreen> {
  DiagnosticsReport? _report;
  bool _running = false;
  bool _showTrace = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _run());
  }

  Future<void> _run() async {
    final settings = ref.read(appSettingsProvider);
    setState(() {
      _running = true;
      _report = null;
    });
    final diag = ConnectionDiagnostics(
      credentials: widget.credentials,
      model: settings.model,
      demoMode: settings.demoMode,
      existingDriver: ref.read(sessionProvider).driver,
      onUpdate: (r) {
        if (mounted) setState(() => _report = r);
      },
    );
    try {
      await diag.run();
    } catch (e) {
      diag.report.trace.add('Unexpected error: $e');
    }
    if (mounted) {
      setState(() {
        _report = diag.report;
        _running = false;
      });
    }
  }

  String _reportText() => _report!.toText(
        gatewayIp: widget.credentials.gatewayIp,
        username: widget.credentials.username,
        model: modelInfo(ref.read(appSettingsProvider).model).displayName,
      );

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final r = _report;
    final demo = ref.watch(appSettingsProvider.select((s) => s.demoMode));

    (IconData, Color) look(DiagStatus s) => switch (s) {
          DiagStatus.running => (Icons.hourglass_top, scheme.primary),
          DiagStatus.ok => (Icons.check_circle, AppColors.download),
          DiagStatus.warn => (Icons.warning_amber_rounded, AppColors.warning),
          DiagStatus.fail => (Icons.cancel, AppColors.danger),
          DiagStatus.skipped => (Icons.remove_circle_outline, scheme.outline),
        };

    return Scaffold(
      appBar: AppBar(title: Text(context.tr('diagTitle'))),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
        children: [
          if (demo)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Card(
                color: AppColors.warning.withValues(alpha: 0.18),
                child: ListTile(
                  leading: const Icon(Icons.science_outlined, color: AppColors.warning),
                  title: Text(context.tr('diagDemoWarning')),
                ),
              ),
            ),
          Card(
            child: Column(children: [
              for (final s in r?.steps ?? const <DiagStep>[])
                ListTile(
                  leading: s.status == DiagStatus.running
                      ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2.5))
                      : Icon(look(s.status).$1, color: look(s.status).$2),
                  title: Text(context.tr('diag_${s.id}')),
                  subtitle: s.detail.isEmpty
                      ? null
                      : Text(s.detail, textDirection: TextDirection.ltr, style: const TextStyle(fontSize: 12)),
                ),
              if (r == null || r.steps.isEmpty)
                const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator())),
            ]),
          ),
          if (r != null && r.finished && !demo) ...[
            const SizedBox(height: 12),
            Card(
              color: (r.allOk ? AppColors.download : AppColors.warning).withValues(alpha: 0.15),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text(context.tr(r.allOk ? 'diagAllOk' : 'diagSomeFailed')),
              ),
            ),
          ],
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: _running ? null : _run,
                icon: const Icon(Icons.replay),
                label: Text(context.tr('diagRunAgain')),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: OutlinedButton.icon(
                style: OutlinedButton.styleFrom(minimumSize: const Size(64, 50)),
                onPressed: r == null || _running
                    ? null
                    : () async {
                        await Clipboard.setData(ClipboardData(text: _reportText()));
                        if (context.mounted) showSnack(context, context.tr('diagCopied'));
                      },
                icon: const Icon(Icons.copy),
                label: Text(context.tr('diagCopy')),
              ),
            ),
          ]),
          const SizedBox(height: 8),
          TextButton.icon(
            onPressed: () => setState(() => _showTrace = !_showTrace),
            icon: Icon(_showTrace ? Icons.expand_less : Icons.expand_more),
            label: Text(context.tr('diagDetails')),
          ),
          if (_showTrace && r != null)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: SelectableText(
                  r.trace.join('\n'),
                  textDirection: TextDirection.ltr,
                  style: TextStyle(fontFamily: 'monospace', fontSize: 11, color: scheme.onSurfaceVariant),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
