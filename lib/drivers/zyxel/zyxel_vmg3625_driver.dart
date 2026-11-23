import 'dart:convert';

import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio/dio.dart';
import 'package:dio_cookie_manager/dio_cookie_manager.dart';
import 'package:flutter/foundation.dart';

import '../router_driver.dart';
import 'zyxel_crypto.dart';
import 'zyxel_endpoints.dart';

/// Driver for the ZYXEL VMG3625-T50B (and close siblings: VMG8825-T50,
/// VMG3925-B10C, EX3301 which share the same "DAL" JSON web API).
///
/// Session flow (as used by the router's own web UI):
///  * `POST /UserLogin` with `Input_Account` + base64(`Input_Passwd`)
///    → `{"result":"ZCFG_SUCCESS","sessionkey":"..."}` + `Session` cookie.
///  * Every following call sends the cookie and `CSRFToken: <sessionkey>`.
///  * Data lives behind `GET/PUT/POST /cgi-bin/DAL?oid=<object>` returning
///    `{"result":"ZCFG_SUCCESS","Object":[ ... ]}`.
///
/// Field names vary slightly between firmware builds, so parsing is lenient
/// (several candidate keys per value) and every endpoint is configurable via
/// [ZyxelEndpoints]. Anything the firmware doesn't support surfaces as a
/// [RouterException] with [RouterErrorCode.notSupported] instead of a crash.
class ZyxelVmg3625Driver extends RouterDriver {
  ZyxelVmg3625Driver(
    super.credentials, {
    this.endpoints = const ZyxelEndpoints(),
    Dio? dio,
  }) : _dio = dio ?? _buildDio(credentials) {
    if (!kIsWeb) {
      // Browsers manage cookies themselves; on Android we keep our own jar.
      _dio.interceptors.add(CookieManager(_cookieJar));
    }
  }

  final ZyxelEndpoints endpoints;
  final Dio _dio;
  final CookieJar _cookieJar = CookieJar();

  String? _sessionKey;
  ZyxelCrypto? _crypto;
  bool _encryptionProbed = false;
  Map<String, dynamic>? _lastWlanObject;
  int _wlanIndex = 1;

  static Dio _buildDio(RouterCredentials c) => Dio(BaseOptions(
        baseUrl: c.baseUrl,
        connectTimeout: const Duration(seconds: 6),
        receiveTimeout: const Duration(seconds: 12),
        sendTimeout: const Duration(seconds: 8),
        responseType: ResponseType.plain, // we decode ourselves (encrypted or not)
        validateStatus: (_) => true,
        followRedirects: false,
        headers: {'Accept': 'application/json, text/plain, */*'},
      ));

  @override
  String get modelName => 'ZYXEL VMG3625-T50B';

  @override
  RouterCapabilities get capabilities =>
      const RouterCapabilities(speedLimitMethod: SpeedLimitMethod.qosShaper);

  @override
  bool get isLoggedIn => _sessionKey != null;

  // ---------------------------------------------------------------------------
  // Session
  // ---------------------------------------------------------------------------

  Future<void> _probeEncryption() async {
    if (_encryptionProbed) return;
    _encryptionProbed = true;
    try {
      final res = await _dio.get<String>(endpoints.rsaPublicKey);
      if (res.statusCode == 200) {
        final body = _decodeJson(res.data);
        final pem = body is Map ? body['RSAPublicKey'] : null;
        if (pem is String && pem.isNotEmpty) {
          _crypto = ZyxelCrypto(pem);
          debugPrint('[Zyxel] encrypted web API detected');
        }
      }
    } on DioException catch (e) {
      throw RouterException(RouterErrorCode.unreachable, e.message);
    } catch (e) {
      debugPrint('[Zyxel] RSA probe failed, using plain JSON: $e');
    }
  }

  @override
  Future<void> login() async {
    await _probeEncryption();
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
      throw RouterException(RouterErrorCode.unreachable, e.message);
    }

    final body = _crypto?.decrypt(_decodeJson(res.data)) ?? _decodeJson(res.data);
    final result = body is Map ? '${body['result'] ?? ''}' : '';
    if (res.statusCode == 200 && result == 'ZCFG_SUCCESS') {
      _sessionKey = '${body['sessionkey'] ?? body['sessionKey'] ?? ''}';
      _dio.options.headers['CSRFToken'] = _sessionKey;
      return;
    }

    final lower = result.toLowerCase();
    if (lower.contains('limit') || lower.contains('already') || lower.contains('lock')) {
      throw RouterException(RouterErrorCode.tooManySessions, result);
    }
    if (res.statusCode == 401 || lower.contains('invalid') || lower.contains('password')) {
      throw RouterException(RouterErrorCode.invalidCredentials, result);
    }
    throw RouterException(
      RouterErrorCode.unexpectedResponse,
      'HTTP ${res.statusCode}: ${_truncate(res.data)}',
    );
  }

  @override
  Future<void> logout() async {
    if (_sessionKey == null) return;
    try {
      await _dio.post<String>(endpoints.logout);
    } catch (_) {
      // Best effort — the router frees idle sessions after a few minutes anyway.
    }
    _sessionKey = null;
    _dio.options.headers.remove('CSRFToken');
  }

  // ---------------------------------------------------------------------------
  // DAL helpers
  // ---------------------------------------------------------------------------

  /// GET /cgi-bin/DAL?oid=… and return the `Object` list.
  Future<List<Map<String, dynamic>>> _dalGet(String oid, {bool retried = false}) async {
    if (!isLoggedIn) await login();
    final Response<String> res;
    try {
      res = await _dio.get<String>(endpoints.dal(oid));
    } on DioException catch (e) {
      throw RouterException(RouterErrorCode.unreachable, e.message);
    }
    if (_isSessionLost(res)) {
      if (retried) throw const RouterException(RouterErrorCode.sessionExpired);
      _sessionKey = null;
      await login();
      return _dalGet(oid, retried: true);
    }
    final body = _crypto?.decrypt(_decodeJson(res.data)) ?? _decodeJson(res.data);
    if (body is! Map || body['result'] != 'ZCFG_SUCCESS') {
      throw RouterException(RouterErrorCode.notSupported, 'oid=$oid → ${_truncate(res.data)}');
    }
    final obj = body['Object'];
    if (obj is List) {
      return obj.whereType<Map>().map((m) => Map<String, dynamic>.from(m)).toList();
    }
    if (obj is Map) return [Map<String, dynamic>.from(obj)];
    return const [];
  }

  /// PUT (update) or POST (create) a DAL object.
  Future<void> _dalWrite(String oid, Map<String, dynamic> data,
      {bool create = false, bool retried = false}) async {
    if (!isLoggedIn) await login();
    final Response<String> res;
    try {
      final body = jsonEncode(_crypto?.encrypt(data) ?? data);
      final opts = Options(contentType: 'application/json');
      res = create
          ? await _dio.post<String>(endpoints.dal(oid), data: body, options: opts)
          : await _dio.put<String>(endpoints.dal(oid), data: body, options: opts);
    } on DioException catch (e) {
      throw RouterException(RouterErrorCode.unreachable, e.message);
    }
    if (_isSessionLost(res)) {
      if (retried) throw const RouterException(RouterErrorCode.sessionExpired);
      _sessionKey = null;
      await login();
      return _dalWrite(oid, data, create: create, retried: true);
    }
    final decoded = _crypto?.decrypt(_decodeJson(res.data)) ?? _decodeJson(res.data);
    if (decoded is! Map || decoded['result'] != 'ZCFG_SUCCESS') {
      throw RouterException(RouterErrorCode.unexpectedResponse, 'oid=$oid → ${_truncate(res.data)}');
    }
  }

  /// Tries each oid in order and returns the first one that works.
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

  bool _isSessionLost(Response<String> res) {
    if (res.statusCode == 401 || res.statusCode == 403) return true;
    if (res.statusCode == 302 || res.statusCode == 301) return true; // redirected to login
    final data = res.data ?? '';
    return data.contains('Invalid Session') || data.contains('login.html');
  }

  // ---------------------------------------------------------------------------
  // RouterDriver API
  // ---------------------------------------------------------------------------

  @override
  Future<RouterStatus> getRouterStatus() async {
    final objs = await _dalGetFirst(endpoints.statusOids);
    final root = objs.first;

    final deviceInfo = _asMap(root['DeviceInfo']) ?? root;
    final dsl = _firstMap(root['DslChannelInfo']) ?? _firstMap(root['DslInfo']);
    final wan = _pickWan(root['WanLanInfo'] ?? root['WanInfo']);

    final wanStatus = '${wan?['Status'] ?? ''}'.toLowerCase();
    final uptimeSecs = _int(_pick(deviceInfo, ['UpTime', 'Uptime', 'X_ZYXEL_UpTime']));
    final dslUp = _int(_pick(dsl, ['UpstreamCurrRate', 'UpstreamRate']));
    final dslDown = _int(_pick(dsl, ['DownstreamCurrRate', 'DownstreamRate']));
    final encapsulation = _pick(dsl, ['LinkEncapsulationUsed', 'StandardUsed']);
    final wanIp = _pick(wan, ['IPAddress', 'IPv4Address', 'ExternalIPAddress']);

    return RouterStatus(
      connected: wanStatus == 'up' || wanStatus == 'connected' || (wanIp != null && '$wanIp'.isNotEmpty),
      model: '${_pick(deviceInfo, ['ModelName', 'ProductClass']) ?? modelName}',
      gatewayIp: credentials.gatewayIp,
      firmwareVersion: _pick(deviceInfo, ['SoftwareVersion', 'FirmwareVersion'])?.toString(),
      wanIp: wanIp?.toString(),
      wanType: [
        _pick(dsl, ['StandardUsed'])?.toString(),
        encapsulation?.toString(),
        _pick(wan, ['Encapsulation', 'Type'])?.toString(),
      ].whereType<String>().where((s) => s.isNotEmpty).toSet().join(' / '),
      lineStatus: _pick(dsl, ['Status'])?.toString() ?? _pick(wan, ['Status'])?.toString(),
      dslDownstreamKbps: dslDown,
      dslUpstreamKbps: dslUp,
      uptime: uptimeSecs == null ? null : Duration(seconds: uptimeSecs),
    );
  }

  @override
  Future<TrafficCounters> getTrafficCounters() async {
    final objs = await _dalGetFirst(endpoints.trafficOids);
    final candidates = <({Map<String, dynamic> stats, int score})>[];

    void walk(dynamic node, String path) {
      if (node is Map) {
        final m = Map<String, dynamic>.from(node);
        final rx = _pick(m, const ['BytesReceived', 'RxBytes', 'X_ZYXEL_BytesReceived']);
        final tx = _pick(m, const ['BytesSent', 'TxBytes', 'X_ZYXEL_BytesSent']);
        if (rx != null && tx != null) {
          final label = '$path ${m['Name'] ?? ''} ${m['Alias'] ?? ''} ${m['X_ZYXEL_IfName'] ?? ''}'
              .toLowerCase();
          var score = 0;
          if (RegExp(r'wan|ppp|ptm|atm|dsl|internet|eth4|nas').hasMatch(label)) score += 10;
          if (RegExp(r'lan|wl|wifi|ssid|br0|iptv|voip|mgmt').hasMatch(label)) score -= 10;
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
      throw const RouterException(
        RouterErrorCode.notSupported,
        'No BytesReceived/BytesSent found. Check ZyxelEndpoints.trafficOids.',
      );
    }
    candidates.sort((a, b) {
      final s = b.score.compareTo(a.score);
      if (s != 0) return s;
      // Tie-break: the busiest interface is almost always the WAN.
      final ar = _int(_pick(a.stats, const ['BytesReceived', 'RxBytes'])) ?? 0;
      final br = _int(_pick(b.stats, const ['BytesReceived', 'RxBytes'])) ?? 0;
      return br.compareTo(ar);
    });
    final best = candidates.first.stats;
    return TrafficCounters(
      rxBytes: _int(_pick(best, const ['BytesReceived', 'RxBytes', 'X_ZYXEL_BytesReceived'])) ?? 0,
      txBytes: _int(_pick(best, const ['BytesSent', 'TxBytes', 'X_ZYXEL_BytesSent'])) ?? 0,
      timestamp: DateTime.now(),
    );
  }

  Map<String, dynamic>? _pickShaper(List<Map<String, dynamic>> rows) {
    if (rows.isEmpty) return null;
    for (final r in rows) {
      final iface = '${r['Interface'] ?? r['IfName'] ?? ''}'.toLowerCase();
      if (endpoints.shaperInterfaceHints.any(iface.contains)) return r;
    }
    return rows.first;
  }

  @override
  Future<SpeedLimit> getWifiSpeedLimit() async {
    try {
      final row = _pickShaper(await _dalGet(endpoints.qosShaperOid));
      if (row == null || row['Enable'] != true) return const SpeedLimit.unlimited();
      final kbps = _int(_pick(row, const ['ShapingRate', 'Rate', 'RateLimit']));
      if (kbps == null || kbps <= 0) return const SpeedLimit.unlimited();
      return SpeedLimit.mbps(kbps / 1000);
    } on RouterException catch (e) {
      if (e.code == RouterErrorCode.notSupported) return const SpeedLimit.unlimited();
      rethrow;
    }
  }

  @override
  Future<SpeedLimitResult> setWifiSpeedLimit(SpeedLimit limit) async {
    try {
      // QoS must be globally enabled for the shaper to take effect.
      if (!limit.isUnlimited) {
        try {
          await _dalWrite(endpoints.qosOid, {'Enable': true});
        } on RouterException catch (e) {
          debugPrint('[Zyxel] enabling global QoS failed (may already be on): $e');
        }
      }

      final rows = await _dalGet(endpoints.qosShaperOid);
      final existing = _pickShaper(rows);
      if (existing == null && limit.isUnlimited) {
        return SpeedLimitResult(
          success: true,
          method: SpeedLimitMethod.qosShaper,
          limit: limit,
          message: 'No shaper configured — already unlimited',
        );
      }
      if (existing == null) {
        // Firmware lists no shaper rows: create one. The Interface value must
        // match what the GUI sends — verify in DevTools (QoS → Shaper → Add).
        await _dalWrite(
          endpoints.qosShaperOid,
          {'Enable': true, 'Interface': 'WAN', 'ShapingRate': limit.kbps},
          create: true,
        );
      } else {
        final updated = Map<String, dynamic>.from(existing)
          ..['Enable'] = !limit.isUnlimited
          ..['ShapingRate'] = limit.kbps ?? existing['ShapingRate'] ?? 0;
        await _dalWrite(endpoints.qosShaperOid, updated);
      }
      return SpeedLimitResult(
        success: true,
        method: SpeedLimitMethod.qosShaper,
        limit: limit,
        message: limit.isUnlimited
            ? 'QoS shaper disabled'
            : 'QoS shaper set to ${limit.kbps} kbps on ${existing?['Interface'] ?? 'WAN'}',
      );
    } on RouterException catch (e) {
      if (e.code == RouterErrorCode.notSupported || e.code == RouterErrorCode.unexpectedResponse) {
        return SpeedLimitResult(
          success: false,
          method: SpeedLimitMethod.unsupported,
          limit: limit,
          message: 'Firmware rejected QoS shaper request (${e.details}). '
              'Use "Open router admin page" → QoS → Shaper, or update ZyxelEndpoints.',
        );
      }
      rethrow;
    }
  }

  @override
  Future<List<ConnectedDevice>> getConnectedDevices() async {
    final objs = await _dalGet(endpoints.lanHostsOid);
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
      final conn = '${_pick(h, const ['X_ZYXEL_ConnectionType', 'InterfaceType', 'Layer1Interface']) ?? ''}'
          .toLowerCase();
      final bandStr = '${_pick(h, const ['X_ZYXEL_WiFiBand', 'WiFiBand', 'X_ZYXEL_Band']) ?? ''}'.toLowerCase();
      WifiBand band;
      if (conn.contains('ether')) {
        band = WifiBand.ethernet;
      } else if (bandStr.contains('5') || conn.contains('5g')) {
        band = WifiBand.band5;
      } else if (bandStr.contains('2.4') || conn.contains('wi') || conn.contains('wl')) {
        band = WifiBand.band24;
      } else {
        band = WifiBand.unknown;
      }
      final name = '${_pick(h, const ['HostName', 'X_ZYXEL_HostName', 'DeviceName']) ?? ''}';
      final mac = '${_pick(h, const ['PhysAddress', 'MACAddress']) ?? ''}'.toUpperCase();
      return ConnectedDevice(
        name: name.isEmpty ? mac : name,
        ip: '${_pick(h, const ['IPAddress', 'IPv4Address']) ?? '-'}',
        mac: mac,
        band: band,
        signalDbm: _int(_pick(h, const ['X_ZYXEL_SignalStrength', 'SignalStrength', 'RSSI'])),
        active: _pick(h, const ['Active']) != false,
      );
    }).toList();
  }

  @override
  Future<WifiSettings> getWifiSettings() async {
    final objs = await _dalGet(endpoints.wlanOid);
    if (objs.isEmpty) throw const RouterException(RouterErrorCode.notSupported, 'wlan');
    // Index 1 is the primary SSID on 2.4 GHz; with band steering both radios share it.
    final primary = objs.firstWhere(
      (o) => _pick(o, const ['wlEnable', 'Enable']) != false,
      orElse: () => objs.first,
    );
    _lastWlanObject = primary;
    _wlanIndex = _int(primary['Index']) ?? 1;
    return WifiSettings(
      ssid: '${_pick(primary, const ['SSID', 'wlSsid']) ?? ''}',
      password: '${_pick(primary, const ['wpaPsk', 'KeyPassphrase', 'PreSharedKey', 'PassPhrase']) ?? ''}',
      enabled: _pick(primary, const ['wlEnable', 'Enable']) != false,
      maxClients: _int(_pick(primary, const ['MaxAssociatedDevices', 'wlMaxAssoc', 'MaxAssocDevices'])) ?? 32,
      txPowerPercent: _int(_pick(primary, const ['TransmitPower', 'wlTxPower', 'X_ZYXEL_TransmitPower'])) ?? 100,
      hidden: _pick(primary, const ['wlHide']) == true,
    );
  }

  @override
  Future<void> updateWifiSettings(WifiSettings settings) async {
    final base = _lastWlanObject ?? {'Index': _wlanIndex};
    final out = Map<String, dynamic>.from(base);
    // Write back using whichever key name the firmware used when reading.
    void put(List<String> keys, Object value) {
      final key = keys.firstWhere(out.containsKey, orElse: () => keys.first);
      out[key] = value;
    }

    put(const ['SSID', 'wlSsid'], settings.ssid);
    put(const ['wpaPsk', 'KeyPassphrase', 'PreSharedKey', 'PassPhrase'], settings.password);
    put(const ['wlEnable', 'Enable'], settings.enabled);
    put(const ['MaxAssociatedDevices', 'wlMaxAssoc', 'MaxAssocDevices'], settings.maxClients);
    put(const ['TransmitPower', 'wlTxPower', 'X_ZYXEL_TransmitPower'], settings.txPowerPercent);
    await _dalWrite(endpoints.wlanOid, out);
    _lastWlanObject = out;
  }

  @override
  Future<DnsSettings> getDns() async {
    final objs = await _dalGet(endpoints.lanDnsOid);
    final lan = objs.first;
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
    final objs = await _dalGet(endpoints.lanDnsOid);
    final out = Map<String, dynamic>.from(objs.first);
    final typeKey = out.containsKey('DNSType') ? 'DNSType' : 'DNS_Type';
    final s1 = out.containsKey('DNSServer1') ? 'DNSServer1' : 'DNS_Servers1';
    final s2 = out.containsKey('DNSServer2') ? 'DNSServer2' : 'DNS_Servers2';
    if (dns.primary == null) {
      out[typeKey] = 'DNS Proxy';
    } else {
      out[typeKey] = 'Static';
      out[s1] = dns.primary;
      out[s2] = dns.secondary ?? '';
    }
    await _dalWrite(endpoints.lanDnsOid, out);
  }

  @override
  Future<void> rebootRouter() async {
    if (!isLoggedIn) await login();
    try {
      final res = await _dio.post<String>(endpoints.reboot);
      if (res.statusCode != 200) {
        throw RouterException(RouterErrorCode.unexpectedResponse, 'HTTP ${res.statusCode}');
      }
    } on DioException catch (e) {
      // The router may drop the connection while going down: that's success.
      if (e.type != DioExceptionType.connectionError &&
          e.type != DioExceptionType.receiveTimeout) {
        throw RouterException(RouterErrorCode.unreachable, e.message);
      }
    }
    _sessionKey = null;
  }

  @override
  void dispose() {
    _dio.close(force: true);
  }

  // ---------------------------------------------------------------------------
  // Parsing helpers (lenient across firmware builds)
  // ---------------------------------------------------------------------------

  static dynamic _decodeJson(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      return jsonDecode(raw);
    } catch (_) {
      return raw;
    }
  }

  static String _truncate(String? s) =>
      s == null ? '' : (s.length > 160 ? '${s.substring(0, 160)}…' : s);

  static dynamic _pick(Map<String, dynamic>? m, List<String> keys) {
    if (m == null) return null;
    for (final k in keys) {
      if (m.containsKey(k) && m[k] != null) return m[k];
    }
    return null;
  }

  static int? _int(dynamic v) {
    if (v == null) return null;
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse('$v'.trim());
  }

  static Map<String, dynamic>? _asMap(dynamic v) =>
      v is Map ? Map<String, dynamic>.from(v) : null;

  static Map<String, dynamic>? _firstMap(dynamic v) {
    if (v is List && v.isNotEmpty && v.first is Map) return Map<String, dynamic>.from(v.first as Map);
    return _asMap(v);
  }

  /// Picks the internet WAN out of a WanLanInfo list (skips LAN / IPTV / VoIP).
  static Map<String, dynamic>? _pickWan(dynamic v) {
    if (v is! List) return _asMap(v);
    final maps = v.whereType<Map>().map((m) => Map<String, dynamic>.from(m)).toList();
    for (final m in maps) {
      final name = '${m['Name'] ?? m['Alias'] ?? ''}'.toLowerCase();
      final type = '${m['Type'] ?? ''}'.toLowerCase();
      if (type == 'lan' || name.contains('lan') || name.contains('iptv') || name.contains('voip')) {
        continue;
      }
      if ('${m['Status']}'.toLowerCase() == 'up') return m;
    }
    return maps.isEmpty ? null : maps.first;
  }
}
