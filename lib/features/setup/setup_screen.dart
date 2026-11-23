import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/config/app_config.dart';
import '../../core/l10n/app_strings.dart';
import '../../core/state/app_state.dart';
import '../../core/widgets/common.dart';
import '../../drivers/driver_registry.dart';
import '../../drivers/mock/mock_router_driver.dart';
import '../../drivers/router_models.dart';

/// Login / router setup. Also reachable from the dashboard to switch router
/// or leave demo mode.
class SetupScreen extends ConsumerStatefulWidget {
  const SetupScreen({super.key, this.pushed = false});

  /// True when opened from inside the app (shows a back button).
  final bool pushed;

  @override
  ConsumerState<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends ConsumerState<SetupScreen> {
  final _form = GlobalKey<FormState>();
  final _ip = TextEditingController(text: AppConfig.defaultGatewayIp);
  final _user = TextEditingController(text: 'admin');
  final _pass = TextEditingController();
  bool _https = false;
  bool _obscure = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _prefill();
  }

  Future<void> _prefill() async {
    final demo = ref.read(appSettingsProvider).demoMode;
    if (demo) {
      _applyDemoCreds();
      return;
    }
    final saved = await ref.read(secureStoreProvider).read();
    if (saved != null && mounted) {
      setState(() {
        _ip.text = saved.gatewayIp;
        _user.text = saved.username;
        _pass.text = saved.password;
        _https = saved.useHttps;
      });
    }
  }

  void _applyDemoCreds() {
    _ip.text = AppConfig.defaultGatewayIp;
    _user.text = MockRouterDriver.demoUsername;
    _pass.text = MockRouterDriver.demoPassword;
  }

  @override
  void dispose() {
    _ip.dispose();
    _user.dispose();
    _pass.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    if (!_form.currentState!.validate()) return;
    setState(() => _busy = true);
    final ok = await ref.read(sessionProvider.notifier).connect(RouterCredentials(
          gatewayIp: _ip.text.trim(),
          username: _user.text.trim(),
          password: _pass.text,
          useHttps: _https,
        ));
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok && widget.pushed) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(appSettingsProvider);
    final session = ref.watch(sessionProvider);
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: widget.pushed,
        title: Text(widget.pushed ? context.tr('routerSettings') : ''),
        actions: [
          TextButton(
            onPressed: () => ref.read(appSettingsProvider.notifier).toggleLocale(),
            child: Text(context.tr('language')),
          ),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Form(
              key: _form,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 32),
                children: [
                  if (!widget.pushed) ...[
                    Icon(Icons.router_rounded, size: 64, color: scheme.primary),
                    const SizedBox(height: 12),
                    Text(context.tr('appFullName'),
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800)),
                    const SizedBox(height: 24),
                  ],
                  Text(context.tr('setupTitle'), style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: 6),
                  Text(context.tr('setupSubtitle'),
                      style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13)),
                  const SizedBox(height: 20),
                  Card(
                    child: SwitchListTile(
                      value: settings.demoMode,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                      title: Text(context.tr('demoMode')),
                      subtitle: Text(context.tr('demoModeHint'), style: const TextStyle(fontSize: 12)),
                      secondary: const Icon(Icons.science_outlined),
                      onChanged: (v) {
                        ref.read(appSettingsProvider.notifier).setDemoMode(v);
                        setState(() {
                          if (v) {
                            _applyDemoCreds();
                          } else {
                            _pass.clear();
                            _prefill();
                          }
                        });
                      },
                    ),
                  ),
                  const SizedBox(height: 16),
                  DropdownButtonFormField<RouterModelId>(
                    initialValue: settings.model,
                    decoration: InputDecoration(
                      labelText: context.tr('routerModel'),
                      prefixIcon: const Icon(Icons.memory),
                    ),
                    items: [
                      for (final m in routerModels)
                        DropdownMenuItem(
                          value: m.id,
                          enabled: m.available,
                          child: Text(
                            m.available ? m.displayName : '${m.displayName} (${context.tr('comingSoon')})',
                            style: m.available ? null : TextStyle(color: scheme.onSurfaceVariant),
                          ),
                        ),
                    ],
                    onChanged: (v) {
                      if (v != null) ref.read(appSettingsProvider.notifier).setModel(v);
                    },
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _ip,
                    keyboardType: TextInputType.url,
                    textDirection: TextDirection.ltr,
                    decoration: InputDecoration(
                      labelText: context.tr('gatewayIp'),
                      prefixIcon: const Icon(Icons.lan_outlined),
                    ),
                    validator: (v) {
                      final s = v?.trim() ?? '';
                      if (s.isEmpty) return context.tr('required');
                      if (!RegExp(r'^[a-zA-Z0-9.\-]+(:\d+)?$').hasMatch(s)) return context.tr('invalidIp');
                      return null;
                    },
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _user,
                    textDirection: TextDirection.ltr,
                    autofillHints: const [AutofillHints.username],
                    decoration: InputDecoration(
                      labelText: context.tr('username'),
                      prefixIcon: const Icon(Icons.person_outline),
                    ),
                    validator: (v) => (v ?? '').trim().isEmpty ? context.tr('required') : null,
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _pass,
                    obscureText: _obscure,
                    textDirection: TextDirection.ltr,
                    autofillHints: const [AutofillHints.password],
                    onFieldSubmitted: (_) => _connect(),
                    decoration: InputDecoration(
                      labelText: context.tr('password'),
                      prefixIcon: const Icon(Icons.lock_outline),
                      suffixIcon: IconButton(
                        icon: Icon(_obscure ? Icons.visibility : Icons.visibility_off),
                        onPressed: () => setState(() => _obscure = !_obscure),
                      ),
                    ),
                    validator: (v) => (v ?? '').isEmpty ? context.tr('required') : null,
                  ),
                  SwitchListTile(
                    contentPadding: const EdgeInsetsDirectional.only(start: 4),
                    value: _https,
                    title: Text(context.tr('useHttps')),
                    onChanged: settings.demoMode ? null : (v) => setState(() => _https = v),
                  ),
                  if (session.phase == SessionPhase.error) ...[
                    const SizedBox(height: 8),
                    ErrorBanner(message: errorText(context, session.error)),
                  ],
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    onPressed: _busy ? null : _connect,
                    icon: _busy
                        ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.login),
                    label: Text(_busy ? context.tr('connecting') : context.tr('connect')),
                  ),
                  if (widget.pushed && session.isConnected) ...[
                    const SizedBox(height: 12),
                    OutlinedButton.icon(
                      onPressed: () async {
                        await ref.read(sessionProvider.notifier).disconnect(forget: true);
                        if (context.mounted) Navigator.of(context).pop();
                      },
                      icon: const Icon(Icons.logout),
                      label: Text(context.tr('disconnect')),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
