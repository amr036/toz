import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../../core/network/local_network.dart';
import '../../drivers/driver_registry.dart';
import '../../drivers/mock/mock_router_driver.dart';
import '../../drivers/router_driver.dart';
import '../../drivers/zyxel/http_adapter_stub.dart' if (dart.library.io) '../../drivers/zyxel/http_adapter_io.dart';
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
    this.existingDriver,
  });

  /// The app's live session, reused when it targets the same router: the
  /// ZYXEL firmware allows a single admin session per user.
  final RouterDriver? existingDriver;

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

  /// Plain reachability over HTTPS and HTTP, independent of any driver.
  Future<String> _reach() async {
    final host = credentials.gatewayIp.split(':').first;
    final results = <String>[];
    var anyOk = false;
    for (final https in [true, false]) {
      final base = RouterCredentials(
        gatewayIp: credentials.gatewayIp,
        username: '',
        password: '',
        useHttps: https,
      ).baseUrl;
      final dio = Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 5),
        receiveTimeout: const Duration(seconds: 8),
        validateStatus: (_) => true,
        followRedirects: false,
        responseType: ResponseType.plain,
      ));
      configureRouterHttp(dio, CookieJar(), host);
      try {
        _log('Reaching $base/ …');
        final res = await dio.get<String>('$base/');
        final body = (res.data ?? '').toLowerCase();
        final brand = body.contains('zyxel') ? ', ZYXEL web UI' : '';
        _log('→ HTTP ${res.statusCode}$brand');
        results.add('${https ? 'HTTPS' : 'HTTP'} ✓ (${res.statusCode}$brand)');
        anyOk = true;
      } on DioException catch (e) {
        _log('→ ${e.type.name}: ${e.error ?? e.message}');
        results.add('${https ? 'HTTPS' : 'HTTP'} ✗ (${e.error ?? e.type.name})');
      } finally {
        dio.close(force: true);
      }
    }
    if (!anyOk) {
      throw RouterException(
        RouterErrorCode.unreachable,
        kIsWeb
            ? 'Browsers block direct requests to the router (CORS). Test from the Android app.'
            : "No answer from ${credentials.gatewayIp}. Is the phone on the router's Wi-Fi "
                '(not mobile data)? Is the IP right? ${results.join('; ')}',
      );
    }
    return results.join(', ');
  }

  /// Logs the (redacted) field layout of the objects the app depends on, so a
  /// report shows exactly what this firmware calls things.
  Future<void> _dumpObjects(ZyxelVmg3625Driver d) async {
    for (final oid in ['Traffic_Status', 'qos', 'wlan', 'lan', 'lanhosts']) {
      try {
        final body = await d.rawDal(oid);
        final obj = body is Map ? body['Object'] : null;
        final first = obj is List && obj.isNotEmpty ? obj.first : obj;
        _log('oid=$oid result=${body is Map ? body['result'] : '?'} → ${_shape(first)}');
      } catch (e) {
        _log('oid=$oid → $e');
      }
    }
  }

  static String _shape(dynamic v, [int depth = 0]) {
    if (v is Map) {
      if (depth >= 2) return '{${v.keys.join(',')}}';
      return '{${v.entries.map((e) => '${e.key}:${_shape(e.value, depth + 1)}').join(', ')}}';
    }
    if (v is List) return v.isEmpty ? '[]' : '[${v.length}× ${_shape(v.first, depth + 1)}]';
    final s = '$v';
    return s.length > 24 ? '${s.substring(0, 24)}…' : s;
  }

  Future<DiagnosticsReport> run() async {
    RouterDriver? driver;
    var ownsDriver = false;
    void Function()? restoreTrace;
    try {
      if (demoMode) {
        _log('Demo mode is ON: testing the simulated router. Turn demo mode off to test your real router.');
      } else {
        await _step('network', () async {
          final net = await localNetworkInfo(gatewayIp: credentials.gatewayIp);
          _log('Phone network: ${net.describe()}');
          if (!kIsWeb && !credentials.gatewayIp.startsWith('127.') && !net.sameSubnetAs(credentials.gatewayIp)) {
            throw RouterException(RouterErrorCode.notOnLan, net.describe());
          }
          return net;
        }, (n) => n.describe());
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

      final live = existingDriver;
      final reuse = live != null &&
          live.isLoggedIn &&
          live.credentials.gatewayIp == credentials.gatewayIp &&
          live.credentials.username == credentials.username &&
          (demoMode ? live is MockRouterDriver : live is! MockRouterDriver);
      if (reuse) _log("Using the app's current router session (the router allows only one).");
      driver = reuse
          ? live
          : demoMode
          ? MockRouterDriver(credentials)
          : model == RouterModelId.zyxelVmg3625T50b
              ? ZyxelVmg3625Driver(credentials, trace: _log)
              : createDriver(model: model, credentials: credentials, demoMode: false);
      final d = driver;
      ownsDriver = !reuse;

      final previousTrace = d is ZyxelVmg3625Driver ? d.trace : null;
      if (reuse && d is ZyxelVmg3625Driver) d.trace = _log;
      restoreTrace = () {
        if (reuse && d is ZyxelVmg3625Driver) d.trace = previousTrace;
      };

      final loggedIn = await _step('login', () async {
        if (!reuse) await d.login();
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
      if (d is ZyxelVmg3625Driver) await _dumpObjects(d);
      return report;
    } finally {
      restoreTrace?.call();
      if (ownsDriver) {
        try {
          await driver?.logout();
        } catch (_) {}
        driver?.dispose();
      }
      report.finished = true;
      onUpdate(report);
    }
  }
}
