import 'package:flutter_test/flutter_test.dart';
import 'package:netpulse_router_manager/drivers/driver_registry.dart';
import 'package:netpulse_router_manager/drivers/router_models.dart';
import 'package:netpulse_router_manager/features/diagnostics/connection_diagnostics.dart';

import 'fake_zyxel_server.dart';

void main() {
  test('all steps pass against a working (encrypted) router', () async {
    final server = FakeZyxelServer();
    await server.start();
    final diag = ConnectionDiagnostics(
      credentials: RouterCredentials(gatewayIp: '127.0.0.1:${server.port}', username: 'admin', password: 'S3cret!'),
      model: RouterModelId.zyxelVmg3625T50b,
      demoMode: false,
      onUpdate: (_) {},
    );
    final r = await diag.run();
    await server.stop();

    expect(r.finished, isTrue);
    expect({for (final s in r.steps) s.id: s.status}, {
      'reach': DiagStatus.ok,
      'login': DiagStatus.ok,
      'status': DiagStatus.ok,
      'traffic': DiagStatus.ok,
      'devices': DiagStatus.ok,
      'wifi': DiagStatus.ok,
      'dns': DiagStatus.ok,
      'speed': DiagStatus.ok,
    });
    expect(r.steps.firstWhere((s) => s.id == 'login').detail, contains('encrypted'));
    expect(server.logoutCount, 1, reason: 'diagnostics must free the admin session');
    final text = r.toText(gatewayIp: '127.0.0.1', username: 'admin', model: 'ZYXEL');
    expect(text, isNot(contains('S3cret!')));
  });

  test('wrong password stops at login with a clear reason', () async {
    final server = FakeZyxelServer();
    await server.start();
    final r = await ConnectionDiagnostics(
      credentials: RouterCredentials(gatewayIp: '127.0.0.1:${server.port}', username: 'admin', password: 'bad'),
      model: RouterModelId.zyxelVmg3625T50b,
      demoMode: false,
      onUpdate: (_) {},
    ).run();
    await server.stop();
    final login = r.steps.firstWhere((s) => s.id == 'login');
    expect(login.status, DiagStatus.fail);
    expect(login.detail, contains('invalidCredentials'));
    expect(r.steps.where((s) => s.status == DiagStatus.skipped), hasLength(6));
  });

  test('unreachable router stops at the first step', () async {
    final r = await ConnectionDiagnostics(
      credentials: const RouterCredentials(gatewayIp: '127.0.0.1:1', username: 'admin', password: 'x'),
      model: RouterModelId.zyxelVmg3625T50b,
      demoMode: false,
      onUpdate: (_) {},
    ).run();
    expect(r.steps.first.status, DiagStatus.fail);
    expect(r.steps.first.detail, contains("router's Wi-Fi"));
  });
}
