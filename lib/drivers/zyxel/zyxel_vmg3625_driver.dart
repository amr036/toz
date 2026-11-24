import 'dart:convert';

import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../router_driver.dart';
import 'http_adapter_stub.dart' if (dart.library.io) 'http_adapter_io.dart';
import 'zyxel_crypto.dart';
import 'zyxel_endpoints.dart';

/// Driver for the ZYXEL VMG3625-T50B and its "DAL API" siblings
/// (VMG8623-T50B, VMG8825-T50, EX3301 …).
///
/// Protocol (V5.50 firmware, confirmed on a real VMG3625-T50B):
///  * Web UI is usually HTTPS-only with a self-signed certificate. The driver
///    tries the configured scheme first and falls back to the other one.
///  * `GET /getRSAPublickKey` → RSA key; login + all payloads are AES-256-CBC
///    encrypted (see [ZyxelCrypto]). Older builds use plain JSON.
///  * `POST /UserLogin` → `{"result":"ZCFG_SUCCESS","sessionkey":…}` + cookie.
///  * Reads: `GET /cgi-bin/DAL?oid=…` (cookie only).
///  * Writes (PUT/POST/DELETE, Reboot, Logout) need `CSRFToken: <sessionkey>`
///    and every successful write returns a NEW sessionkey (CSRF rotation).
///    Using a stale one gives HTTP 403.
///  * One admin session per user ("Duplicated login"); idle timeout ≈ 5 min.
class ZyxelVmg3625Driver extends RouterDriver {
  ZyxelVmg3625Driver(
    super.credentials, {
    this.endpoints = const ZyxelEndpoints(),
    this.trace,
    Dio? dio,
  }) : _dio = dio ?? _buildDio(credentials) {
    // Self-signed certificates are accepted ONLY for the gateway host.
    configureRouterHttp(_dio, _cookieJar, credentials.gatewayIp.split(':').first);
  }

  final ZyxelEndpoints endpoints;

  /// Optional step-by-step log (connection test screen). Never receives
  /// passwords or session keys.
  void Function(String line)? trace;

  final Dio _dio;
  final CookieJar _cookieJar = CookieJar();

  String? _sessionKey;
  ZyxelCrypto? _crypto;
  bool _probed = false;
  Map<String, dynamic>? _lastWlanObject;

  bool get usingHttps => _dio.options.baseUrl.startsWith('https');
  bool get encrypted => _crypto != null;

  static Dio _buildDio(RouterCredentials c) => Dio(BaseOptions(
        baseUrl: c.baseUrl,
        connectTimeout: const Duration(seconds: 6),
        receiveTimeout: const Duration(seconds: 15),
        sendTimeout: const Duration(seconds: 8),
        responseType: ResponseType.plain, // decoded (and decrypted) by us
        validateStatus: (_) => true,
        followRedirects: false,
        headers: {
          'Accept': 'application/json, text/plain, */*',
          'X-Requested-With': 'XMLHttpRequest',
        },
      ));

  void _log(String line) {
    trace?.call(line);
    if (kDebugMode) debugPrint('[Zyxel] $line');
  }

  @override
  String get modelName => 'ZYXEL VMG3625-T50B';

  @override
  RouterCapabilities get capabilities =>
      const RouterCapabilities(speedLimitMethod: SpeedLimitMethod.qosShaper);

  @override
  bool get isLoggedIn => _sessionKey != null;

  @override
  Uri get adminPageUri => Uri.parse(_dio.options.baseUrl);

  // ---------------------------------------------------------------------------
  // Transport
  // ---------------------------------------------------------------------------

  RouterException _netError(DioException e) {
    final cause = e.error ?? e.message ?? e.type.name;
    final msg = switch (e.type) {
      DioExceptionType.connectionTimeout => 'Connection timed out (${_dio.options.baseUrl})',
      DioExceptionType.receiveTimeout => 'Router did not answer in time',
      _ => 'Cannot talk to ${_dio.options.baseUrl}: $cause',
    };
    _log('NETWORK ERROR: $msg');
    return RouterException(RouterErrorCode.unreachable, msg);
  }

  String _otherScheme(String base) => base.startsWith('https://')
      ? base.replaceFirst('https://', 'http://')
      : base.replaceFirst('http://', 'https://');

  /// Finds a working scheme (HTTP or HTTPS) and whether payloads are encrypted.
  Future<void> _probe() async {
    if (_probed) return;
    DioException? firstError;
    Response<String>? root;
    for (final base in [_dio.options.baseUrl, _otherScheme(_dio.options.baseUrl)]) {
      _dio.options.baseUrl = base;
      try {
        root = await _dio.get<String>('/');
        _log('GET $base/ → HTTP ${root.statusCode}');
        final loc = root.headers.value('location') ?? '';
        if ((root.statusCode ?? 0) ~/ 100 == 3 && loc.startsWith('https://') && !usingHttps) {
          _log('Router redirects to HTTPS');
          continue;
        }
        break;
      } on DioException catch (e) {
        _log('GET $base/ failed: ${e.error ?? e.type.name}');
        firstError ??= e;
        root = null;
      }
    }
    if (root == null) throw _netError(firstError!);
    _log('Using ${_dio.options.baseUrl}');

    try {
      final res = await _dio.get<String>(endpoints.rsaPublicKey);
      final body = _decodeJson(res.data);
      final pem = body is Map ? body['RSAPublicKey'] : null;
      if (res.statusCode == 200 && pem is String && pem.isNotEmpty) {
        _crypto = ZyxelCrypto(pem);
        _log('Encrypted web API (RSA + AES-256-CBC)');
      } else {
        _log('Plain JSON web API (no RSA key, HTTP ${res.statusCode})');
      }
    } on DioException catch (e) {
      throw _netError(e);
    } catch (e) {
      _log('RSA key could not be used ($e) → plain JSON');
    }
    _probed = true;
  }

  dynamic _decodeBody(Response<String> res) {
    final raw = _decodeJson(res.data);
    dynamic body;
    try {
      body = _crypto?.decrypt(raw) ?? raw;
    } catch (e) {
      _log('Could not decrypt response: $e');
      body = raw;
    }
    // CSRF rotation: any response may carry the next sessionkey.
    if (body is Map) {
      final next = body['sessionkey'] ?? body['sessionKey'];
      if (next != null && '$next'.isNotEmpty && _sessionKey != null && '$next' != _sessionKey) {
        _sessionKey = '$next';
        _dio.options.headers['CSRFToken'] = _sessionKey;
      }
    }
    return body;
  }

  // ---------------------------------------------------------------------------
  // Session
  // ---------------------------------------------------------------------------

  @override
  Future<void> login() async {
    await _probe();
    final payload = {
      'Input_Account': credentials.username,
      'Input_Passwd': base64Encode(utf8.encode(credentials.password)),
      'currLang': 'en',
      'RememberPassword': 0,
      'SHA512_password': false,
    };

    final Response<String> res;
    try {
      res = await _dio.post<String>(
        endpoints.login,
        data: jsonEncode(_crypto?.encrypt(payload) ?? payload),
        options: Options(contentType: 'application/json'),
      );
    } on DioException catch (e) {
      throw _netError(e);
    }

    final raw = _decodeJson(res.data);
    dynamic body;
    try {
      body = _crypto?.decrypt(raw) ?? raw;
    } catch (_) {
      body = raw;
    }
    final result = body is Map ? '${body['result'] ?? ''}' : '';
    final reply = body is Map ? '${body['replyMsg'] ?? body['ReplyMsg'] ?? body['message'] ?? ''}' : '';
    _log('POST ${endpoints.login} (user "${credentials.username}") → HTTP ${res.statusCode}, '
        'result="$result"${reply.isEmpty ? '' : ', reply="$reply"'}');

    if (res.statusCode == 200 && result == 'ZCFG_SUCCESS') {
      _sessionKey = '${body['sessionkey'] ?? body['sessionKey'] ?? ''}';
      _dio.options.headers['CSRFToken'] = _sessionKey;
      _log('Logged in');
      return;
    }

    final lower = '$result $reply'.toLowerCase();
    if (lower.contains('locked')) {
      final secs = RegExp(r'\d+').firstMatch(reply)?.group(0);
      throw RouterException(RouterErrorCode.lockedOut, secs == null ? result : '$secs s');
    }
    if (lower.contains('duplicat') || lower.contains('already') || lower.contains('limit') ||
        lower.contains('a user exist') || lower.contains('maxium') || lower.contains('maximum')) {
      throw RouterException(RouterErrorCode.tooManySessions, result);
    }
    if (lower.contains('invalid') || lower.contains('password') || lower.contains('incorrect') ||
        lower.contains('permission denied') ||
        res.statusCode == 401) {
      throw RouterException(RouterErrorCode.invalidCredentials, result);
    }
    throw RouterException(RouterErrorCode.unexpectedResponse, 'HTTP ${res.statusCode}: ${_preview(body)}');
  }

  @override
  Future<void> logout() async {
    if (_sessionKey == null) return;
    try {
      final res = await _dio.post<String>(endpoints.logout);
      _log('POST ${endpoints.logout} → HTTP ${res.statusCode}');
    } catch (_) {
      // Best effort — the router frees idle sessions after ~5 minutes anyway.
    }
    _sessionKey = null;
    _dio.options.headers.remove('CSRFToken');
  }

  Future<void> _relogin(String why) async {
    _log('$why → logging in again');
    _sessionKey = null;
    _dio.options.headers.remove('CSRFToken');
    await login();
  }

  // ---------------------------------------------------------------------------
  // DAL
  // ---------------------------------------------------------------------------

  /// Raw decoded body of `GET /cgi-bin/DAL?oid=…`, with secrets removed
  /// (for the connection test report).
  Future<dynamic> rawDal(String oid) async {
    if (!isLoggedIn) await login();
    try {
      final res = await _dio.get<String>(endpoints.dal(oid));
      return redactSecrets(_decodeBody(res));
    } on DioException catch (e) {
      throw _netError(e);
    }
  }

  /// GET /cgi-bin/DAL?oid=… → the `Object` list.
  Future<List<Map<String, dynamic>>> _dalGet(String oid, {bool retried = false}) async {
    if (!isLoggedIn) await login();
    final Response<String> res;
    try {
      res = await _dio.get<String>(endpoints.dal(oid));
    } on DioException catch (e) {
      throw _netError(e);
    }
    final body = _decodeBody(res);
    if (_sessionLost(res, body)) {
      if (retried) throw const RouterException(RouterErrorCode.sessionExpired);
      await _relogin('GET oid=$oid: session expired (HTTP ${res.statusCode})');
      return _dalGet(oid, retried: true);
    }
    if (body is! Map || body['result'] != 'ZCFG_SUCCESS') {
      _log('GET oid=$oid → HTTP ${res.statusCode}: ${_preview(body)}');
      throw RouterException(RouterErrorCode.notSupported, 'oid=$oid → ${_preview(body)}');
    }
    final obj = body['Object'];
    final out = obj is List
        ? obj.whereType<Map>().map((m) => Map<String, dynamic>.from(m)).toList()
        : obj is Map
            ? [Map<String, dynamic>.from(obj)]
            : <Map<String, dynamic>>[];
    _log('GET oid=$oid → OK (${out.length} object${out.length == 1 ? '' : 's'})');
    return out;
  }

  /// Any CSRF-protected write. Retries once after re-login on 401/403/504
  /// (stale sessionkey). Returns the decoded body.
  Future<dynamic> _write(String method, String path, {Map<String, dynamic>? data, bool retried = false}) async {
    if (!isLoggedIn) await login();
    final Response<String> res;
    try {
      res = await _dio.request<String>(
        path,
        data: data == null ? null : jsonEncode(_crypto?.encrypt(data) ?? data),
        options: Options(method: method, contentType: 'application/json'),
      );
    } on DioException catch (e) {
      throw _netError(e);
    }
    final body = _decodeBody(res);
    final status = res.statusCode ?? 0;
    _log('$method $path → HTTP $status${body is Map ? ', result="${body['result']}"' : ''}');
    if ((status == 401 || status == 403 || status == 504) && !retried) {
      await _relogin('$method $path rejected (HTTP $status, stale session)');
      return _write(method, path, data: data, retried: true);
    }
    if (status == 401 || status == 403) {
      throw RouterException(RouterErrorCode.sessionExpired, 'HTTP $status');
    }
    return body;
  }

  Future<void> _dalWrite(String oid, Map<String, dynamic> data, {bool create = false}) async {
    final body = await _write(create ? 'POST' : 'PUT', endpoints.dal(oid), data: data);
    if (body is! Map || body['result'] != 'ZCFG_SUCCESS') {
      throw RouterException(RouterErrorCode.unexpectedResponse, 'oid=$oid → ${_preview(body)}');
    }
  }

  Future<List<Map<String, dynamic>>> _dalGetFirst(List<String> oids) async {
    RouterException? last;
    for (final oid in oids) {
      try {
        final objs = await _dalGet(oid);
        if (objs.isNotEmpty) return objs;
      } on RouterException catch (e) {
        if (e.code != RouterErrorCode.notSupported) rethrow;
        last = e;
      }
    }
    throw last ?? RouterException(RouterErrorCode.notSupported, oids.join(','));
  }

  bool _sessionLost(Response<String> res, dynamic body) {
    final s = res.statusCode ?? 0;
    if (s == 401 || s == 403 || s == 301 || s == 302) return true;
    final r = body is Map ? '${body['result']}'.toLowerCase() : '${res.data}'.toLowerCase();
    return r.contains('invalid session') || r.contains('login.html');
  }

  // ---------------------------------------------------------------------------
  // RouterDriver API
  // ---------------------------------------------------------------------------

  @override
  Future<RouterStatus> getRouterStatus() async {
    final root = (await _dalGetFirst(endpoints.statusOids)).first;
    final deviceInfo = _asMap(root['DeviceInfo']) ?? root;
    final dsl = _firstMap(root['DslChannelInfo']) ?? _firstMap(root['DslInfo']);
    final wan = _pickWan(root['WanLanInfo'] ?? root['WanInfo']);

    final wanStatus = '${wan?['Status'] ?? ''}'.toLowerCase();
    final uptimeSecs = _int(_pick(deviceInfo, const ['UpTime', 'Uptime', 'X_ZYXEL_UpTime']));
    final wanIp = _wanIp(wan);

    return RouterStatus(
      connected: wanStatus == 'up' || wanStatus == 'connected' || (wanIp != null && wanIp != '0.0.0.0'),
      model: '${_pick(deviceInfo, const ['ModelName', 'ProductClass']) ?? modelName}',
      gatewayIp: credentials.gatewayIp,
      firmwareVersion: _pick(deviceInfo, const ['SoftwareVersion', 'FirmwareVersion'])?.toString(),
      wanIp: wanIp,
      wanType: [
        _pick(dsl, const ['StandardUsed'])?.toString(),
        _pick(dsl, const ['LinkEncapsulationUsed'])?.toString(),
        _pick(wan, const ['Encapsulation', 'LinkType'])?.toString(),
        root['WanType']?.toString(),
      ].whereType<String>().where((s) => s.isNotEmpty).toSet().join(' / '),
      lineStatus: _pick(dsl, const ['Status'])?.toString() ?? _pick(wan, const ['Status'])?.toString(),
      dslDownstreamKbps: _int(_pick(dsl, const ['DownstreamCurrRate', 'DownstreamRate'])),
      dslUpstreamKbps: _int(_pick(dsl, const ['UpstreamCurrRate', 'UpstreamRate'])),
      uptime: uptimeSecs == null ? null : Duration(seconds: uptimeSecs),
    );
  }

  static String? _wanIp(Map<String, dynamic>? wan) {
    if (wan == null) return null;
    final v4 = wan['IPv4Address'];
    if (v4 is List && v4.isNotEmpty && v4.first is Map) {
      final ip = (v4.first as Map)['IPAddress'];
      if (ip != null && '$ip'.isNotEmpty) return '$ip';
    }
    if (v4 is String && v4.isNotEmpty) return v4;
    final ip = _pick(wan, const ['IPAddress', 'ExternalIPAddress']);
    return ip == null || '$ip'.isEmpty ? null : '$ip';
  }

  @override
  Future<TrafficCounters> getTrafficCounters() async {
    final objs = await _dalGetFirst(endpoints.trafficOids);
    const rxKeys = ['BytesReceived', 'X_ZYXEL_BytesReceived', 'RxBytes'];
    const txKeys = ['BytesSent', 'X_ZYXEL_BytesSent', 'TxBytes'];
    final candidates = <({Map<String, dynamic> stats, int score})>[];

    void walk(dynamic node, String path) {
      if (node is Map) {
        final m = Map<String, dynamic>.from(node);
        if (_pick(m, rxKeys) != null && _pick(m, txKeys) != null) {
          final label = '$path ${m['Name'] ?? ''} ${m['Alias'] ?? ''} ${m['X_ZYXEL_IfName'] ?? ''} '
                  '${m['X_ZYXEL_SrvName'] ?? ''} ${m['LowerLayers'] ?? ''}'
              .toLowerCase();
          var score = 0;
          if (RegExp(r'ppp|wan|ptm|atm|dsl|internet|nas').hasMatch(label)) score += 10;
          if (RegExp(r'lan|wl|wifi|ssid|br0|iptv|voip|mgmt|ethernet\.interface\.[1-4]\b').hasMatch(label)) {
            score -= 10;
          }
          candidates.add((stats: m, score: score));
        }
        m.forEach((k, v) => walk(v, '$path/$k'));
      } else if (node is List) {
        for (final e in node) {
          walk(e, path);
        }
      }
    }

    for (final o in objs) {
      walk(o, '');
    }
    if (candidates.isEmpty) {
      throw const RouterException(RouterErrorCode.notSupported, 'no BytesReceived/BytesSent in Traffic_Status');
    }
    candidates.sort((a, b) {
      final s = b.score.compareTo(a.score);
      if (s != 0) return s;
      return (_int(_pick(b.stats, rxKeys)) ?? 0).compareTo(_int(_pick(a.stats, rxKeys)) ?? 0);
    });
    final best = candidates.first.stats;
    return TrafficCounters(
      rxBytes: _int(_pick(best, rxKeys)) ?? 0,
      txBytes: _int(_pick(best, txKeys)) ?? 0,
      timestamp: DateTime.now(),
    );
  }

  // ---- Speed limit ----------------------------------------------------------
  //
  // VMG3625-T50B QoS → General has "LAN Managed Downstream Bandwidth": a cap
  // on the total download rate delivered to LAN + Wi-Fi clients. That is the
  // whole-network "Wi-Fi speed limit". (QoS → Shaper only limits WAN upload
  // and rejects non-WAN interfaces, as seen on real hardware.)

  static String? _downKey(Map<String, dynamic> qos) {
    for (final k in qos.keys) {
      final l = k.toLowerCase();
      if (l.contains('down') && !l.contains('priority') && !l.contains('enable') && _int(qos[k]) != null) {
        return k;
      }
    }
    return null;
  }

  static String _enableKey(Map<String, dynamic> qos) =>
      const ['Enable', 'QosEnable', 'X_ZYXEL_Enable'].firstWhere(qos.containsKey, orElse: () => 'Enable');

  @override
  Future<SpeedLimit> getWifiSpeedLimit() async {
    try {
      final qos = (await _dalGet(endpoints.qosOid)).firstOrNull;
      if (qos == null) return const SpeedLimit.unlimited();
      final key = _downKey(qos);
      final enabled = qos[_enableKey(qos)];
      final kbps = key == null ? null : _int(qos[key]);
      if ((enabled == true || enabled == 1 || enabled == '1') && kbps != null && kbps > 0) {
        return SpeedLimit.mbps(kbps / 1000);
      }
      return const SpeedLimit.unlimited();
    } on RouterException catch (e) {
      if (e.code == RouterErrorCode.notSupported) return const SpeedLimit.unlimited();
      rethrow;
    }
  }

  @override
  Future<SpeedLimitResult> setWifiSpeedLimit(SpeedLimit limit) async {
    try {
      final qos = (await _dalGet(endpoints.qosOid)).firstOrNull;
      final key = qos == null ? null : _downKey(qos);
      if (qos == null || key == null) {
        return SpeedLimitResult(
          success: false,
          method: SpeedLimitMethod.unsupported,
          limit: limit,
          message: 'QoS page has no downstream bandwidth field '
              '(fields: ${qos?.keys.join(', ') ?? 'none'}). Send the connection-test report to the developer.',
        );
      }
      final out = Map<String, dynamic>.from(qos);
      final enableKey = _enableKey(qos);
      final asString = qos[key] is String;
      if (limit.isUnlimited) {
        out[enableKey] = false;
      } else {
        out[enableKey] = true;
        out[key] = asString ? '${limit.kbps}' : limit.kbps;
      }
      await _dalWrite(endpoints.qosOid, out);
      return SpeedLimitResult(
        success: true,
        method: SpeedLimitMethod.qosShaper,
        limit: limit,
        message: limit.isUnlimited ? 'QoS disabled (no limit)' : 'QoS $key = ${limit.kbps} kbps',
      );
    } on RouterException catch (e) {
      if (e.code == RouterErrorCode.notSupported || e.code == RouterErrorCode.unexpectedResponse) {
        return SpeedLimitResult(
          success: false,
          method: SpeedLimitMethod.unsupported,
          limit: limit,
          message: 'Router rejected the QoS change: ${e.details}',
        );
      }
      rethrow;
    }
  }

  // ---- Devices ---------------------------------------------------------------

  static WifiBand _band(Map<String, dynamic> h) {
    final conn = '${_pick(h, const ['X_ZYXEL_ConnectionType', 'InterfaceType']) ?? ''}'.toLowerCase();
    final l1 = '${h['Layer1Interface'] ?? ''}'.toLowerCase();
    final std = '${_pick(h, const ['X_ZYXEL_OperatingStandard', 'OperatingStandard']) ?? ''}'.toLowerCase();
    final bandStr = '${_pick(h, const ['X_ZYXEL_WiFiBand', 'WiFiBand', 'X_ZYXEL_Band']) ?? ''}'.toLowerCase();
    if (conn.contains('ether') || l1.contains('ethernet')) return WifiBand.ethernet;
    final isWifi = conn.contains('wi') || conn.contains('wl') || l1.contains('wifi') || std.isNotEmpty;
    if (!isWifi) return WifiBand.unknown;
    if (bandStr.contains('5')) return WifiBand.band5;
    if (bandStr.contains('2.4')) return WifiBand.band24;
    // 802.11a / ac / ax are 5 GHz standards ("ax" can be both; treat as 5).
    if (RegExp(r'\ba\b|ac|ax').hasMatch(std.replaceAll(',', ' ').replaceAll('/', ' '))) return WifiBand.band5;
    if (std.isNotEmpty) return WifiBand.band24;
    // Layer1Interface "WiFi.SSID.N": 1-4 = 2.4 GHz, 5-8 = 5 GHz on T50 builds.
    final n = int.tryParse(RegExp(r'ssid\.(\d+)').firstMatch(l1)?.group(1) ?? '');
    if (n != null) return n >= 5 ? WifiBand.band5 : WifiBand.band24;
    return WifiBand.unknown;
  }

  @override
  Future<List<ConnectedDevice>> getConnectedDevices() async {
    final objs = await _dalGet(endpoints.lanHostsOid);
    final blockedMacs = await _blockedMacs();
    final hosts = <Map<String, dynamic>>[];
    for (final o in objs) {
      final list = o['lanhosts'] ?? o['LanHosts'] ?? o['Hosts'];
      if (list is List) {
        hosts.addAll(list.whereType<Map>().map((m) => Map<String, dynamic>.from(m)));
      } else if (o.containsKey('PhysAddress')) {
        hosts.add(o);
      }
    }
    return hosts.map((h) {
      final name = '${_pick(h, const ['curHostName', 'HostName', 'X_ZYXEL_HostName', 'DeviceName']) ?? ''}';
      final mac = '${_pick(h, const ['PhysAddress', 'MACAddress']) ?? ''}'.toUpperCase();
      final active = _pick(h, const ['Active']);
      final band = _band(h);
      // ZYXEL reports 0-5 bars in X_ZYXEL_SignalStrength (0 for wired);
      // a negative number would be dBm.
      final sig = _int(_pick(h, const ['X_ZYXEL_SignalStrength', 'SignalStrength', 'RSSI']));
      return ConnectedDevice(
        name: name.isEmpty ? mac : name,
        ip: '${_pick(h, const ['IPAddress', 'IPv4Address']) ?? '-'}',
        mac: mac,
        band: band,
        signalDbm: sig != null && sig < 0 ? sig : null,
        signalLevel: sig != null && sig >= 0 && band != WifiBand.ethernet ? sig.clamp(0, 5) : null,
        active: _truthy(active ?? true),
        blocked: blockedMacs.contains(mac) || _truthy(h['Internet_Blocking_Enable'] ?? false),
        // Router-side counters: "Sent" = router → device = downloaded.
        downloadedBytes: _int(_pick(h, const ['X_ZYXEL_BytesSent', 'BytesSent'])),
        uploadedBytes: _int(_pick(h, const ['X_ZYXEL_BytesReceived', 'BytesReceived'])),
        vendor: _pick(h, const ['VendorClassID'])?.toString(),
      );
    }).toList();
  }

  // ---- Blocking (Parental Control) ------------------------------------------
  //
  // The T50 firmware blocks a device through a Parental Control profile
  // (oid=paren_ctl) holding its MAC and an all-week, all-day block window.
  // The app owns profiles named "NP-<last 6 MAC hex>" and deletes them to
  // unblock, leaving the user's own profiles untouched.

  static const _days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

  static String profileName(String mac) => 'NP-${mac.replaceAll(':', '').toUpperCase().substring(6)}';

  static String _normMac(String mac) => mac.toUpperCase().replaceAll('-', ':');

  Future<List<Map<String, dynamic>>> _profiles() async {
    try {
      return await _dalGet(endpoints.parentalOid);
    } on RouterException catch (e) {
      if (e.code == RouterErrorCode.notSupported) return const [];
      rethrow;
    }
  }

  /// MACs currently blocked by profiles this app created.
  Future<Set<String>> _blockedMacs() async {
    final out = <String>{};
    for (final p in await _profiles()) {
      if (!'${p['pcpName']}'.startsWith('NP-') || !_truthy(p['pcpEnable'] ?? 1)) continue;
      for (final m in '${p['MACAddressList'] ?? ''}'.split(',')) {
        if (m.trim().isNotEmpty) out.add(_normMac(m.trim()));
      }
    }
    return out;
  }

  @override
  Future<void> setDeviceBlocked(String mac, bool blocked) async {
    final m = _normMac(mac);
    final name = profileName(m);
    final existing = (await _profiles()).where((p) => p['pcpName'] == name).toList();
    if (blocked) {
      if (existing.isNotEmpty) {
        final p = Map<String, dynamic>.from(existing.first)
          ..['pcpEnable'] = 1
          ..['MACAddressList'] = m
          ..['Days'] = _days
          ..['TimeRangeList'] = '00:00-23:59';
        await _dalWrite(endpoints.parentalOid, p);
      } else {
        await _dalWrite(
          endpoints.parentalOid,
          {
            'pcpName': name,
            'pcpEnable': 1,
            'MACAddressList': m,
            'Days': _days,
            'TimeRangeList': '00:00-23:59',
            'ServicePolicy': 'Block',
            'UrlPolicy': 'Block',
            'WebRedirect': 0,
            'URLFilter': '',
            'NetworkServiceList': '',
          },
          create: true,
        );
      }
      // Parental control must be switched on globally for profiles to apply.
      try {
        await _dalWrite(endpoints.parentalOid, {'PrentalCtlEnable': '1'});
      } on RouterException catch (e) {
        _log('Enabling parental control globally failed (may already be on): ${e.details}');
      }
    } else {
      for (final p in existing) {
        final body = await _write('DELETE', '${endpoints.dal(endpoints.parentalOid)}&Index=${p['Index']}');
        if (body is Map && body['result'] != null && body['result'] != 'ZCFG_SUCCESS') {
          throw RouterException(RouterErrorCode.unexpectedResponse, _preview(body));
        }
      }
    }
  }

  // ---- Wi-Fi ------------------------------------------------------------------

  static const _ssidKeys = ['SSID', 'wlSsid'];
  static const _passKeys = ['wpaPsk', 'KeyPassphrase', 'PreSharedKey', 'PassPhrase', 'wifiPassword'];
  static const _enableKeys = ['wlEnable', 'Enable'];
  static const _maxKeys = ['MaxAssociatedDevices', 'wlMaxAssoc', 'MaxAssocDevices'];
  static const _txKeys = ['TransmitPower', 'wlTxPower', 'X_ZYXEL_TransmitPower'];

  static bool _truthy(dynamic v) => !(v == false || v == 0 || v == '0' || v == 'false');

  @override
  Future<WifiSettings> getWifiSettings() async {
    List<Map<String, dynamic>> objs = const [];
    try {
      objs = await _dalGet(endpoints.wlanOid);
    } on RouterException catch (e) {
      if (e.code != RouterErrorCode.notSupported) rethrow;
    }
    final withSsid = objs.where((o) => _pick(o, _ssidKeys) != null).toList();
    if (withSsid.isNotEmpty) {
      final primary = withSsid.firstWhere((o) => _truthy(_pick(o, _enableKeys)), orElse: () => withSsid.first);
      _lastWlanObject = primary;
      return WifiSettings(
        ssid: '${_pick(primary, _ssidKeys) ?? ''}',
        password: '${_pick(primary, _passKeys) ?? ''}',
        enabled: _truthy(_pick(primary, _enableKeys)),
        maxClients: _int(_pick(primary, _maxKeys)) ?? 32,
        txPowerPercent: _int(_pick(primary, _txKeys)) ?? 100,
        hidden: _pick(primary, const ['wlHide']) == true,
      );
    }
    // Fallback: the status page lists every SSID with its password.
    final status = (await _dalGetFirst(endpoints.statusOids)).first;
    final wifi = (status['WiFiInfo'] as List?)?.whereType<Map>().map((m) => Map<String, dynamic>.from(m)).toList() ??
        const [];
    if (wifi.isEmpty) throw const RouterException(RouterErrorCode.notSupported, 'no Wi-Fi info');
    final primary = wifi.firstWhere((w) => _truthy(w['Enable']), orElse: () => wifi.first);
    return WifiSettings(
      ssid: '${primary['SSID'] ?? ''}',
      password: '${primary['wifiPassword'] ?? ''}',
      enabled: _truthy(primary['Enable']),
    );
  }

  @override
  Future<void> updateWifiSettings(WifiSettings settings) async {
    final base = _lastWlanObject;
    if (base == null) {
      throw const RouterException(RouterErrorCode.notSupported, 'Wi-Fi object (oid=wlan) not available');
    }
    final out = Map<String, dynamic>.from(base);
    void put(List<String> keys, Object value) {
      final key = keys.firstWhere(out.containsKey, orElse: () => keys.first);
      out[key] = value;
    }

    put(_ssidKeys, settings.ssid);
    put(_passKeys, settings.password);
    put(_enableKeys, settings.enabled);
    if (_pick(base, _maxKeys) != null) put(_maxKeys, settings.maxClients);
    if (_pick(base, _txKeys) != null) put(_txKeys, settings.txPowerPercent);
    await _dalWrite(endpoints.wlanOid, out);
    _lastWlanObject = out;
  }

  // ---- DNS ----------------------------------------------------------------------

  @override
  Future<DnsSettings> getDns() async {
    final lan = (await _dalGet(endpoints.lanDnsOid)).first;
    final type = '${_pick(lan, const ['DNS_Type', 'DNSType']) ?? ''}'.toLowerCase();
    // "From ISP" / "DNS Proxy" mean the router relays the ISP's DNS.
    if (!(type.contains('static') || type.contains('user'))) return const DnsSettings();
    return DnsSettings(
      primary: _pick(lan, const ['DNS_Servers1', 'DNSServer1'])?.toString(),
      secondary: _pick(lan, const ['DNS_Servers2', 'DNSServer2'])?.toString(),
    );
  }

  @override
  Future<void> setDns(DnsSettings dns) async {
    final lan = Map<String, dynamic>.from((await _dalGet(endpoints.lanDnsOid)).first);
    final typeKey = lan.containsKey('DNSType') ? 'DNSType' : 'DNS_Type';
    final s1 = lan.containsKey('DNSServer1') ? 'DNSServer1' : 'DNS_Servers1';
    final s2 = lan.containsKey('DNSServer2') ? 'DNSServer2' : 'DNS_Servers2';
    final changes = <String, dynamic>{
      if (dns.primary == null) typeKey: 'DNS Proxy' else ...{
        typeKey: 'Static',
        s1: dns.primary,
        s2: dns.secondary ?? '',
      },
    };
    // Identity fields that tell the router which LAN object is meant.
    final identity = {
      for (final k in const ['Index', 'Name', 'Group', 'Interface', 'BrName', 'IPAddress', 'SubnetMask'])
        if (lan.containsKey(k)) k: lan[k],
    };

    // Sending the whole object back fails on real firmware because of
    // unrelated IPv6 fields ("IPv6_IdentifierType"), so try, in order:
    //  1. only the DNS fields (+ identity),
    //  2. the full object without any IPv6 fields,
    //  3. the full object.
    final attempts = <Map<String, dynamic>>[
      {...identity, ...changes},
      {
        for (final e in lan.entries)
          if (!e.key.toLowerCase().contains('ipv6') && !e.key.toLowerCase().startsWith('v6')) e.key: e.value,
        ...changes,
      },
      {...lan, ...changes},
    ];
    RouterException? last;
    for (var i = 0; i < attempts.length; i++) {
      try {
        await _dalWrite(endpoints.lanDnsOid, attempts[i]);
        _log('DNS saved (attempt ${i + 1})');
        return;
      } on RouterException catch (e) {
        if (e.code != RouterErrorCode.unexpectedResponse) rethrow;
        _log('DNS attempt ${i + 1} rejected: ${e.details}');
        last = e;
      }
    }
    throw last!;
  }

  // ---- Reboot ----------------------------------------------------------------------

  @override
  Future<void> rebootRouter() async {
    try {
      final body = await _write('POST', endpoints.reboot);
      if (body is Map && body['result'] != null && body['result'] != 'ZCFG_SUCCESS') {
        throw RouterException(RouterErrorCode.unexpectedResponse, _preview(body));
      }
    } on RouterException catch (e) {
      // The router may drop the connection while going down: that's success.
      if (e.code != RouterErrorCode.unreachable) rethrow;
    }
    _sessionKey = null;
    _probed = false;
  }

  @override
  void dispose() {
    _dio.close(force: true);
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  static final _secretKey = RegExp(r'pass|psk|key|secret|token', caseSensitive: false);

  /// Removes passwords, Wi-Fi keys and session keys before anything is shown
  /// or logged.
  static dynamic redactSecrets(dynamic v) {
    if (v is Map) {
      return {
        for (final e in v.entries)
          '${e.key}': _secretKey.hasMatch('${e.key}') && e.value is! Map && e.value is! List
              ? '***'
              : redactSecrets(e.value),
      };
    }
    if (v is List) return v.map(redactSecrets).toList();
    return v;
  }

  static String _preview(dynamic body) {
    final clean = redactSecrets(body);
    final s = clean is String ? clean : jsonEncode(clean);
    return s.length > 200 ? '${s.substring(0, 200)}…' : s;
  }

  static dynamic _decodeJson(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      return jsonDecode(raw);
    } catch (_) {
      return raw;
    }
  }

  static dynamic _pick(Map<String, dynamic>? m, List<String> keys) {
    if (m == null) return null;
    for (final k in keys) {
      if (m.containsKey(k) && m[k] != null) return m[k];
    }
    return null;
  }

  static int? _int(dynamic v) {
    if (v == null || v is bool) return null;
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse('$v'.trim());
  }

  static Map<String, dynamic>? _asMap(dynamic v) => v is Map ? Map<String, dynamic>.from(v) : null;

  static Map<String, dynamic>? _firstMap(dynamic v) {
    if (v is List) {
      final m = v.whereType<Map>().firstOrNull;
      return m == null ? null : Map<String, dynamic>.from(m);
    }
    return _asMap(v);
  }

  /// Internet WAN out of WanLanInfo (skips LAN / IPTV / VoIP / management).
  static Map<String, dynamic>? _pickWan(dynamic v) {
    if (v is! List) return _asMap(v);
    final maps = v.whereType<Map>().map((m) => Map<String, dynamic>.from(m)).toList();
    Map<String, dynamic>? firstWan;
    for (final m in maps) {
      final name = '${m['X_ZYXEL_SrvName'] ?? m['Name'] ?? m['Alias'] ?? ''}'.toLowerCase();
      final type = '${m['Type'] ?? ''}'.toLowerCase();
      if (type == 'lan' || name == 'lan' || name.contains('iptv') || name.contains('voip') ||
          name.contains('tr069') || name.contains('mgmt')) {
        continue;
      }
      firstWan ??= m;
      if ('${m['Status']}'.toLowerCase() == 'up' && _wanIp(m) != null) return m;
    }
    return firstWan ?? maps.firstOrNull;
  }
}
