import 'package:flutter_test/flutter_test.dart';
import 'package:netpulse_router_manager/drivers/driver_registry.dart';
import 'package:netpulse_router_manager/drivers/router_driver.dart';
import 'package:netpulse_router_manager/drivers/zyxel/zyxel_vmg3625_driver.dart';
import 'package:netpulse_router_manager/features/diagnostics/connection_diagnostics.dart';

import 'fake_zyxel_server.dart';

const _pass = '11223344';

void main() {
  late FakeZyxelServer server;
  setUp(() async {
    server = FakeZyxelServer(); // HTTPS-only, encrypted — like the real router
    await server.start();
  });
  tearDown(() => server.stop());

  RouterCredentials creds([String pass = _pass]) =>
      RouterCredentials(gatewayIp: '127.0.0.1:${server.port}', username: 'admin', password: pass);

  Future<DiagnosticsReport> run(RouterCredentials c, {RouterDriver? existing}) => ConnectionDiagnostics(
        credentials: c,
        model: RouterModelId.zyxelVmg3625T50b,
        demoMode: false,
        existingDriver: existing,
        onUpdate: (_) {},
      ).run();

  test('all steps pass against an HTTPS-only encrypted router', () async {
    final r = await run(creds());
    expect({for (final s in r.steps) s.id: s.status}, {
      for (final id in ['reach', 'login', 'status', 'traffic', 'devices', 'wifi', 'dns', 'speed']) id: DiagStatus.ok,
    });
    expect(r.steps.first.detail, contains('HTTPS ✓'), reason: 'self-signed certificate accepted');
    expect(r.steps.firstWhere((s) => s.id == 'login').detail, contains('HTTPS'));
    expect(r.trace.join('\n'), contains('oid=qos'), reason: 'report includes field layout');
    expect(server.logoutCount, 1);
    final text = r.toText(gatewayIp: '192.168.1.1', username: 'admin', model: 'ZYXEL');
    expect(RegExp(r'(?<![0-9A-Za-z])11223344(?![0-9])').hasMatch(text), isFalse);
  });

  test('reuses the app session instead of failing with "Duplicated login"', () async {
    final app = ZyxelVmg3625Driver(creds());
    await app.login();
    final r = await run(creds(), existing: app);
    expect(r.steps.every((s) => s.status == DiagStatus.ok), isTrue,
        reason: r.steps.map((s) => '${s.id}:${s.status.name} ${s.detail}').join('\n'));
    expect(server.loginCount, 1);
    expect(app.isLoggedIn, isTrue, reason: 'the app session stays open');
    expect(app.trace, isNull, reason: 'trace hook restored');
    app.dispose();
  });

  test('wrong password stops at login', () async {
    final r = await run(creds('bad'));
    final login = r.steps.firstWhere((s) => s.id == 'login');
    expect(login.status, DiagStatus.fail);
    expect(login.detail, contains('invalidCredentials'));
  });

  test('unreachable router reports the real cause for both schemes', () async {
    final r = await run(const RouterCredentials(gatewayIp: '127.0.0.1:1', username: 'admin', password: 'x'));
    expect(r.steps.first.status, DiagStatus.fail);
    expect(r.steps.first.detail, allOf(contains('HTTPS ✗'), contains('HTTP ✗')));
    expect(r.steps.first.detail, isNot(contains('(unknown)')));
  });
}
