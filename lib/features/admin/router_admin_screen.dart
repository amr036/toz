import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../core/l10n/app_strings.dart';
import '../../core/state/app_state.dart';

/// Fallback: the router's own web admin UI inside a WebView, for anything
/// the app doesn't cover natively (port forwarding, parental control, …).
class RouterAdminScreen extends ConsumerStatefulWidget {
  const RouterAdminScreen({super.key});

  @override
  ConsumerState<RouterAdminScreen> createState() => _RouterAdminScreenState();
}

class _RouterAdminScreenState extends ConsumerState<RouterAdminScreen> {
  WebViewController? _controller;
  int _progress = 0;

  bool get _demo => ref.read(appSettingsProvider).demoMode;

  Uri? get _uri => ref.read(sessionProvider).driver?.adminPageUri;

  @override
  void initState() {
    super.initState();
    if (!kIsWeb && !_demo && _uri != null) {
      _controller = WebViewController()
        ..setJavaScriptMode(JavaScriptMode.unrestricted)
        ..setNavigationDelegate(NavigationDelegate(
          onProgress: (p) => setState(() => _progress = p),
        ))
        ..loadRequest(_uri!);
    }
  }

  @override
  Widget build(BuildContext context) {
    final uri = _uri;
    return Scaffold(
      appBar: AppBar(
        title: Text(context.tr('openAdmin')),
        actions: [
          if (_controller != null)
            IconButton(icon: const Icon(Icons.refresh), onPressed: () => _controller!.reload()),
        ],
        bottom: _controller != null && _progress < 100
            ? PreferredSize(
                preferredSize: const Size.fromHeight(3),
                child: LinearProgressIndicator(value: _progress / 100),
              )
            : null,
      ),
      body: _controller != null
          ? WebViewWidget(controller: _controller!)
          : Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.web_asset_off_outlined, size: 56, color: Theme.of(context).colorScheme.primary),
                  const SizedBox(height: 16),
                  Text(context.tr(_demo ? 'adminDemo' : 'adminWebOnly'), textAlign: TextAlign.center),
                  if (!_demo && uri != null) ...[
                    const SizedBox(height: 20),
                    FilledButton.icon(
                      onPressed: () => launchUrl(uri, webOnlyWindowName: '_blank'),
                      icon: const Icon(Icons.open_in_new),
                      label: Text(context.tr('openInBrowser')),
                    ),
                  ],
                ]),
              ),
            ),
    );
  }
}
