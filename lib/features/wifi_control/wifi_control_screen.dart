import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/config/app_config.dart';
import '../../core/l10n/app_strings.dart';
import '../../core/state/app_state.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/formatters.dart';
import '../../core/widgets/app_top_bar.dart';
import '../../core/widgets/common.dart';
import '../../drivers/router_driver.dart';

RouterDriver _driverOf(Ref ref) {
  final d = ref.watch(sessionProvider.select((s) => s.driver));
  if (d == null) throw const RouterException(RouterErrorCode.sessionExpired);
  return d;
}

final speedLimitProvider = FutureProvider<SpeedLimit>((ref) => _driverOf(ref).getWifiSpeedLimit());
final wifiSettingsProvider = FutureProvider<WifiSettings>((ref) => _driverOf(ref).getWifiSettings());
final dnsProvider = FutureProvider<DnsSettings>((ref) => _driverOf(ref).getDns());

class WifiControlScreen extends ConsumerWidget {
  const WifiControlScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppTopBar(title: context.tr('navWifi')),
      body: RefreshIndicator(
        onRefresh: () async {
          ref.invalidate(speedLimitProvider);
          ref.invalidate(wifiSettingsProvider);
          ref.invalidate(dnsProvider);
          await ref.read(speedLimitProvider.future).catchError((_) => const SpeedLimit.unlimited());
        },
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
          children: [
            SectionTitle(context.tr('speedLimiter')),
            const _SpeedLimiterCard(),
            SectionTitle(context.tr('wifiSettings')),
            const _WifiSettingsCard(),
            SectionTitle(context.tr('dns')),
            const _DnsCard(),
          ],
        ),
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// Speed limiter
// -----------------------------------------------------------------------------

class _SpeedLimiterCard extends ConsumerStatefulWidget {
  const _SpeedLimiterCard();

  @override
  ConsumerState<_SpeedLimiterCard> createState() => _SpeedLimiterCardState();
}

class _SpeedLimiterCardState extends ConsumerState<_SpeedLimiterCard> {
  /// null = not yet chosen by user (mirror active); 0 = unlimited.
  double? _selected;
  bool _customMode = false;
  double _custom = 15;
  bool _applying = false;
  SpeedLimitResult? _lastResult;

  Future<void> _apply() async {
    final mbps = _customMode ? _custom : (_selected ?? 0);
    final limit = mbps <= 0 ? const SpeedLimit.unlimited() : SpeedLimit.mbps(mbps);
    setState(() => _applying = true);
    try {
      final r = await requireDriver(ref).setWifiSpeedLimit(limit);
      if (!mounted) return;
      setState(() => _lastResult = r);
      ref.invalidate(speedLimitProvider);
      showSnack(context, r.success ? context.tr('applied') : (r.message ?? context.tr('applyFailed')),
          error: !r.success);
    } catch (e) {
      if (mounted) showSnack(context, errorText(context, e), error: true);
    } finally {
      if (mounted) setState(() => _applying = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final active = ref.watch(speedLimitProvider);
    final driver = ref.watch(sessionProvider.select((s) => s.driver));
    final scheme = Theme.of(context).colorScheme;
    final activeMbps = active.value?.mbps ?? 0;
    final current = _customMode ? null : (_selected ?? activeMbps);

    Widget preset(double mbps) {
      final selected = !_customMode && current == mbps;
      final isActive = active.hasValue && activeMbps == mbps;
      final label = mbps == 0 ? context.tr('unlimited') : formatMbps(mbps);
      return _PresetCard(
        label: label,
        icon: mbps == 0 ? Icons.all_inclusive : Icons.speed,
        selected: selected,
        active: isActive,
        activeLabel: context.tr('activeLimit'),
        onTap: () => setState(() {
          _customMode = false;
          _selected = mbps;
        }),
      );
    }

    final presets = <double>[0, ...AppConfig.speedPresetsMbps];
    final customActive = active.hasValue && activeMbps != 0 && !presets.contains(activeMbps);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(Icons.network_check, color: scheme.primary),
            const SizedBox(width: 8),
            Text('${context.tr('activeLimit')}: '),
            active.when(
              data: (l) => Chip(
                visualDensity: VisualDensity.compact,
                backgroundColor: (l.isUnlimited ? AppColors.download : AppColors.warning).withValues(alpha: 0.2),
                label: Text(l.isUnlimited ? context.tr('unlimited') : formatMbps(l.mbps!),
                    style: const TextStyle(fontWeight: FontWeight.w700)),
              ),
              loading: () => const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
              error: (e, _) => Text('—', style: TextStyle(color: scheme.error)),
            ),
          ]),
          const SizedBox(height: 12),
          LayoutBuilder(builder: (context, c) {
            final cols = c.maxWidth > 520 ? 5 : 3;
            final w = (c.maxWidth - 8 * (cols - 1)) / cols;
            return Wrap(spacing: 8, runSpacing: 8, children: [
              for (final p in presets) SizedBox(width: w, child: preset(p)),
              SizedBox(
                width: w,
                child: _PresetCard(
                  label: context.tr('custom'),
                  icon: Icons.tune,
                  selected: _customMode,
                  active: customActive,
                  activeLabel: context.tr('activeLimit'),
                  onTap: () => setState(() {
                    _customMode = true;
                    if (customActive) _custom = activeMbps;
                  }),
                ),
              ),
            ]);
          }),
          AnimatedSize(
            duration: const Duration(milliseconds: 200),
            child: _customMode
                ? Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Row(children: [
                      Expanded(
                        child: Slider(
                          min: 1,
                          max: 100,
                          divisions: 99,
                          value: _custom.clamp(1, 100),
                          label: formatMbps(_custom),
                          onChanged: (v) => setState(() => _custom = v.roundToDouble()),
                        ),
                      ),
                      SizedBox(
                        width: 84,
                        child: Text(formatMbps(_custom),
                            textAlign: TextAlign.end,
                            style: const TextStyle(fontWeight: FontWeight.w700)),
                      ),
                    ]),
                  )
                : const SizedBox(width: double.infinity),
          ),
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _applying ? null : _apply,
              icon: _applying
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.check),
              label: Text(context.tr('apply')),
            ),
          ),
          const SizedBox(height: 10),
          Text(
            '${context.tr('method')}: ${context.tr('method_${(_lastResult?.method ?? driver?.capabilities.speedLimitMethod ?? SpeedLimitMethod.unsupported).name}')}'
            '${_lastResult?.message != null ? '\n${_lastResult!.message}' : ''}',
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          ),
        ]),
      ),
    );
  }
}

class _PresetCard extends StatelessWidget {
  const _PresetCard({
    required this.label,
    required this.icon,
    required this.selected,
    required this.active,
    required this.activeLabel,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final bool selected;
  final bool active;
  final String activeLabel;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      decoration: BoxDecoration(
        color: selected ? scheme.primaryContainer : scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: selected ? scheme.primary : Colors.transparent, width: 2),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 6),
          child: Column(children: [
            Icon(icon, color: selected ? scheme.onPrimaryContainer : scheme.onSurfaceVariant),
            const SizedBox(height: 6),
            Text(label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  color: selected ? scheme.onPrimaryContainer : null,
                )),
            const SizedBox(height: 4),
            AnimatedOpacity(
              opacity: active ? 1 : 0,
              duration: const Duration(milliseconds: 180),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(color: AppColors.download, borderRadius: BorderRadius.circular(6)),
                child: Text(activeLabel,
                    style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w800, color: Colors.black)),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// Wi-Fi settings
// -----------------------------------------------------------------------------

class _WifiSettingsCard extends ConsumerStatefulWidget {
  const _WifiSettingsCard();

  @override
  ConsumerState<_WifiSettingsCard> createState() => _WifiSettingsCardState();
}

class _WifiSettingsCardState extends ConsumerState<_WifiSettingsCard> {
  final _form = GlobalKey<FormState>();
  final _ssid = TextEditingController();
  final _pass = TextEditingController();
  int _maxClients = 32;
  double _tx = 100;
  bool _obscure = true;
  bool _saving = false;
  WifiSettings? _loaded;

  @override
  void dispose() {
    _ssid.dispose();
    _pass.dispose();
    super.dispose();
  }

  void _fill(WifiSettings w) {
    if (identical(_loaded, w)) return;
    _loaded = w;
    _ssid.text = w.ssid;
    _pass.text = w.password;
    _maxClients = w.maxClients;
    _tx = w.txPowerPercent.toDouble();
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate() || _loaded == null) return;
    setState(() => _saving = true);
    try {
      await requireDriver(ref).updateWifiSettings(_loaded!.copyWith(
        ssid: _ssid.text.trim(),
        password: _pass.text,
        maxClients: _maxClients,
        txPowerPercent: _tx.round(),
      ));
      ref.invalidate(wifiSettingsProvider);
      if (mounted) showSnack(context, context.tr('wifiSaved'));
    } catch (e) {
      if (mounted) showSnack(context, errorText(context, e), error: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(wifiSettingsProvider);
    final caps = ref.watch(sessionProvider.select((s) => s.driver?.capabilities));
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: async.when(
          loading: () => const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: CircularProgressIndicator()),
          ),
          error: (e, _) => ErrorBanner(
            message: errorText(context, e),
            onRetry: () => ref.invalidate(wifiSettingsProvider),
          ),
          data: (w) {
            _fill(w);
            return Form(
              key: _form,
              child: Column(children: [
                TextFormField(
                  controller: _ssid,
                  maxLength: 32,
                  decoration: InputDecoration(labelText: context.tr('ssid'), prefixIcon: const Icon(Icons.wifi)),
                  validator: (v) => (v ?? '').trim().isEmpty ? context.tr('required') : null,
                ),
                const SizedBox(height: 4),
                TextFormField(
                  controller: _pass,
                  obscureText: _obscure,
                  maxLength: 63,
                  textDirection: TextDirection.ltr,
                  decoration: InputDecoration(
                    labelText: context.tr('wifiPassword'),
                    prefixIcon: const Icon(Icons.key),
                    suffixIcon: IconButton(
                      icon: Icon(_obscure ? Icons.visibility : Icons.visibility_off),
                      onPressed: () => setState(() => _obscure = !_obscure),
                    ),
                  ),
                  validator: (v) => (v ?? '').length < 8 ? context.tr('passwordMin') : null,
                ),
                if (caps?.canLimitClients ?? true)
                  Row(children: [
                    const Icon(Icons.devices),
                    const SizedBox(width: 12),
                    Expanded(child: Text(context.tr('maxClients'))),
                    IconButton.filledTonal(
                      icon: const Icon(Icons.remove),
                      onPressed: _maxClients > 1 ? () => setState(() => _maxClients--) : null,
                    ),
                    SizedBox(
                      width: 40,
                      child: Text('$_maxClients',
                          textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.w800)),
                    ),
                    IconButton.filledTonal(
                      icon: const Icon(Icons.add),
                      onPressed: _maxClients < 64 ? () => setState(() => _maxClients++) : null,
                    ),
                  ]),
                if (caps?.canSetTxPower ?? true) ...[
                  const SizedBox(height: 12),
                  Row(children: [
                    const Icon(Icons.signal_wifi_4_bar),
                    const SizedBox(width: 12),
                    Expanded(child: Text(context.tr('txPower'))),
                    Text('${_tx.round()}%', style: const TextStyle(fontWeight: FontWeight.w800)),
                  ]),
                  Slider(
                    min: 0,
                    max: 100,
                    divisions: 4, // most firmwares accept 20/40/60/80/100 %
                    value: (_tx / 25).round() * 25.0,
                    label: '${_tx.round()}%',
                    onChanged: (v) => setState(() => _tx = v),
                  ),
                ],
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: _saving ? null : _save,
                    icon: _saving
                        ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.save_outlined),
                    label: Text(context.tr('save')),
                  ),
                ),
              ]),
            );
          },
        ),
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// DNS
// -----------------------------------------------------------------------------

class _DnsCard extends ConsumerStatefulWidget {
  const _DnsCard();

  @override
  ConsumerState<_DnsCard> createState() => _DnsCardState();
}

class _DnsCardState extends ConsumerState<_DnsCard> {
  DnsPreset? _choice;
  final _p = TextEditingController();
  final _s = TextEditingController();
  bool _saving = false;

  static const _presets = [
    DnsPreset.ispDefault,
    DnsPreset.cloudflare,
    DnsPreset.cloudflareFamily,
    DnsPreset.adguardFamily,
    DnsPreset.google,
    DnsPreset.custom,
  ];

  @override
  void dispose() {
    _p.dispose();
    _s.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final choice = _choice;
    if (choice == null) return;
    final dns = choice == DnsPreset.custom
        ? DnsSettings(primary: _p.text.trim(), secondary: _s.text.trim().isEmpty ? null : _s.text.trim())
        : DnsSettings.fromPreset(choice);
    if (choice == DnsPreset.custom && (dns.primary ?? '').isEmpty) return;
    setState(() => _saving = true);
    try {
      await requireDriver(ref).setDns(dns);
      ref.invalidate(dnsProvider);
      if (mounted) showSnack(context, context.tr('dnsSaved'));
    } catch (e) {
      if (mounted) showSnack(context, errorText(context, e), error: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(dnsProvider);
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: async.when(
          loading: () => const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: CircularProgressIndicator()),
          ),
          error: (e, _) => ErrorBanner(message: errorText(context, e), onRetry: () => ref.invalidate(dnsProvider)),
          data: (dns) {
            final current = dns.preset;
            final choice = _choice ?? current;
            return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(context.tr('dnsHint'), style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
              const SizedBox(height: 8),
              RadioGroup<DnsPreset>(
                groupValue: choice,
                onChanged: (v) => setState(() {
                  _choice = v;
                  if (v == DnsPreset.custom && _p.text.isEmpty) {
                    _p.text = dns.primary ?? '';
                    _s.text = dns.secondary ?? '';
                  }
                }),
                child: Column(children: [
                  for (final p in _presets)
                    RadioListTile<DnsPreset>(
                      value: p,
                      contentPadding: EdgeInsets.zero,
                      title: Text(context.tr('dns_${p.name}')),
                      subtitle: p.primary == null
                          ? null
                          : Text('${p.primary}, ${p.secondary}', textDirection: TextDirection.ltr),
                      secondary: p == current
                          ? Icon(Icons.check_circle, color: AppColors.download, semanticLabel: context.tr('activeLimit'))
                          : null,
                    ),
                ]),
              ),
              if (choice == DnsPreset.custom) ...[
                TextField(
                  controller: _p,
                  textDirection: TextDirection.ltr,
                  keyboardType: TextInputType.url,
                  decoration: InputDecoration(labelText: context.tr('primaryDns')),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _s,
                  textDirection: TextDirection.ltr,
                  keyboardType: TextInputType.url,
                  decoration: InputDecoration(labelText: context.tr('secondaryDns')),
                ),
              ],
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: _saving ? null : _save,
                  icon: _saving
                      ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.dns_outlined),
                  label: Text(context.tr('apply')),
                ),
              ),
            ]);
          },
        ),
      ),
    );
  }
}
