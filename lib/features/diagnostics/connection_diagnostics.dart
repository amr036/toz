import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../../drivers/driver_registry.dart';
import '../../drivers/mock/mock_router_driver.dart';
import '../../drivers/router_driver.dart';
import '../../drivers/zyxel/zyxel_vmg3625_driver.dart';
import '../usage/domain/usage_models.dart';

enum DiagStatus { running, ok, warn, fail, skipped }

class DiagStep {
  DiagStep(this.id, {this.status = DiagStatus.running, this.detail = ''});
  final String id;
  DiagStatus status;
  String detail;
}

class DiagnosticsReport {
  final steps = <DiagStep>[];
  final trace = <String>[];
  bool finished = false;

  bool get allOk => steps.every((s) => s.status == DiagStatus.ok || s.status == DiagStatus.skipped);

  /// Plain-text report the user can copy and send. Never contains the password.
  String toText({required String gatewayIp, required String username, required String model}) {
    final b = StringBuffer()
      ..writeln('NetPulse connection report')
      ..writeln('Time: ${DateTime.now().toIso8601String()}')
      ..writeln('Platform: ${kIsWeb ? 'web' : defaultTargetPlatform.name}')
      ..writeln('Router: $model @ $gatewayIp (user "$username")')
      ..writeln();
    for (final s in steps) {
      b.writeln('[${s.status.name.toUpperCase()}] ${s.id}${s.detail.isEmpty ? '' : ' — ${s.detail}'}');
    }
    b
      ..writeln()
      ..writeln('--- trace ---');
    trace.forEach(b.writeln);
    return b.toString();
  }
}

/// Step-by-step check of the path phone → router → login → each API used by
/// the app, so a failure on real hardware can be pinpointed (and fixed in
/// ZyxelEndpoints) without guessing.
class ConnectionDiagnostics {
  ConnectionDiagnostics({
    required this.credentials,
    required this.model,
    required this.demoMode,
    required this.onUpdate,
  });

  final RouterCredentials credentials;
  final RouterModelId model;
  final bool demoMode;
  final void Function(DiagnosticsReport report) onUpdate;

  final report = DiagnosticsReport();

  void _log(String line) {
    final t = DateTime.now();
    final ts = '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:'
        '${t.second.toString().padLeft(2, '0')}';
    report.trace.add('$ts $line');
    onUpdate(report);
  }

  Future<T?> _step<T>(String id, Future<T> Function() body, String Function(T value) describe) async {
    final step = DiagStep(id);
    report.steps.add(step);
    onUpdate(report);
    try {
      final v = await body();
      step
        ..status = DiagStatus.ok
        ..detail = describe(v);
      return v;
    } on RouterException catch (e) {
      step
        ..status = e.code == RouterErrorCode.notSupported ? DiagStatus.warn : DiagStatus.fail
        ..detail = '${e.code.name}${e.details == null ? '' : ': ${e.details}'}';
    } catch (e) {
      step
        ..status = DiagStatus.fail
        ..detail = '$e';
    } finally {
      onUpdate(report);
    }
    return null;
  }

  void _skip(String id, String why) {
    report.steps.add(DiagStep(id, status: DiagStatus.skipped, detail: why));
    onUpdate(report);
  }

  /// Plain HTTP reachability, independent of any router driver.
  Future<String> _reach() async {
    final dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 5),
      receiveTimeout: const Duration(seconds: 8),
      validateStatus: (_) => true,
      followRedirects: false,
      responseType: ResponseType.plain,
    ));
    try {
      final url = '${credentials.baseUrl}/';
      _log('Reaching $url …');
      final res = await dio.get<String>(url);
      final body = (res.data ?? '').toLowerCase();
      final brand = body.contains('zyxel')
          ? 'ZYXEL web UI detected'
          : body.contains('huawei')
              ? 'Huawei web UI detected'
              : body.contains('zte')
                  ? 'ZTE web UI detected'
                  : 'brand not recognised';
      final loc = res.headers.value('location');
      _log('→ HTTP ${res.statusCode}${loc == null ? '' : ' (redirect to $loc)'}, $brand');
      return 'HTTP ${res.statusCode}, $brand${loc == null ? '' : ', redirects to $loc'}';
    } on DioException catch (e) {
      _log('→ ${e.type.name}: ${e.error ?? e.message}');
      throw RouterException(
        RouterErrorCode.unreachable,
        kIsWeb
            ? 'Browsers block direct requests to the router (CORS). Test from the Android app.'
            : 'No answer from ${credentials.gatewayIp}. Is the phone on the router\'s Wi-Fi '
                '(not mobile data)? Is the IP right? (${e.type.name})',
      );
    } finally {
      dio.close(force: true);
    }
  }

  Future<DiagnosticsReport> run() async {
    RouterDriver? driver;
    try {
      if (demoMode) {
        _log('Demo mode is ON: testing the simulated router. Turn demo mode off to test your real router.');
      } else {
        final reached = await _step('reach', _reach, (s) => s);
        if (reached == null) {
          for (final id in ['login', 'status', 'traffic', 'devices', 'wifi', 'dns', 'speed']) {
            _skip(id, 'router not reachable');
          }
          return report;
        }
      }

      if (!demoMode && !modelInfo(model).available) {
        for (final id in ['login', 'status', 'traffic', 'devices', 'wifi', 'dns', 'speed']) {
          _skip(id, 'driver for ${modelInfo(model).displayName} not implemented yet');
        }
        return report;
      }

      driver = demoMode
          ? MockRouterDriver(credentials)
          : model == RouterModelId.zyxelVmg3625T50b
              ? ZyxelVmg3625Driver(credentials, trace: _log)
              : createDriver(model: model, credentials: credentials, demoMode: false);
      final d = driver;

      final loggedIn = await _step('login', () async {
        await d.login();
        return true;
      }, (_) {
        if (d is ZyxelVmg3625Driver) {
          return '${d.encrypted ? 'encrypted' : 'plain'} API${d.usingHttps ? ', HTTPS' : ''}';
        }
        return 'OK';
      });
      if (loggedIn == null) {
        for (final id in ['status', 'traffic', 'devices', 'wifi', 'dns', 'speed']) {
          _skip(id, 'login failed');
        }
        return report;
      }

      await _step('status', d.getRouterStatus,
          (s) => '${s.model}, internet ${s.connected ? 'UP' : 'DOWN'}, WAN ${s.wanIp ?? '?'}, '
              'fw ${s.firmwareVersion ?? '?'}');
      await _step('traffic', d.getTrafficCounters,
          (c) => 'RX ${bytesToGb(c.rxBytes).toStringAsFixed(2)} GB, TX ${bytesToGb(c.txBytes).toStringAsFixed(2)} GB');
      await _step('devices', d.getConnectedDevices, (l) => '${l.length} devices');
      await _step('wifi', d.getWifiSettings, (w) => 'SSID "${w.ssid}"');
      await _step('dns', d.getDns, (x) => x.primary ?? 'ISP default');
      await _step('speed', d.getWifiSpeedLimit, (l) => l.isUnlimited ? 'unlimited' : '${l.mbps} Mbps');
      return report;
    } finally {
      try {
        await driver?.logout();
      } catch (_) {}
      driver?.dispose();
      report.finished = true;
      onUpdate(report);
    }
  }
}
