import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:encrypt/encrypt.dart' as enc;
import 'package:pointycastle/asn1.dart';
import 'package:pointycastle/export.dart';

/// In-process imitation of a ZYXEL VMG3625-T50B (firmware V5.50) web API,
/// modelled on behaviour seen on real hardware (all identifiers below are
/// fictional test values):
///  * HTTPS only, self-signed certificate (plain HTTP on that port fails).
///  * RSA key exchange + AES-256-CBC payloads (or plain JSON if [encrypted]
///    is false).
///  * Reads need only the session cookie; writes need `CSRFToken`, and every
///    successful write returns a NEW sessionkey. A stale key → HTTP 403.
///  * One admin session per user: another client logging in while a session
///    is active gets "Duplicated login".
///  * QoS → Shaper rejects non-WAN interfaces with ZCFG_INVALID_PARAM_VALUE.
class FakeZyxelServer {
  FakeZyxelServer({
    this.encrypted = true,
    this.https = true,
    this.wlanAvailable = true,
    this.username = 'admin',
    this.password = '11223344',
  });

  final bool encrypted;
  final bool https;

  /// When false, oid=wlan answers success with an empty list (as unknown
  /// oids do on real firmware), forcing the WiFiInfo fallback.
  final bool wlanAvailable;
  final String username;
  final String password;

  late HttpServer _server;
  late RSAPrivateKey _priv;
  late String _publicPem;

  /// session cookie → (csrf key, aes key)
  final _sessions = <String, ({String csrf, Uint8List? aesKey})>{};
  int loginCount = 0;
  int logoutCount = 0;
  int rebootCount = 0;
  int staleCsrfRejections = 0;
  final requests = <String>[];

  // Mutable router state.
  Map<String, dynamic> wlan = {
    'Index': 1,
    'wlEnable': true,
    'SSID': 'WE_ABC123',
    'wpaPsk': '11223344',
    'MaxAssociatedDevices': 32,
    'TransmitPower': 100,
  };
  /// LAN setup as read back from the router. Like real firmware, a PUT that
  /// echoes IPv6_IdentifierType back is rejected.
  Map<String, dynamic> lan = {
    'Index': 1,
    'IPAddress': '192.168.1.1',
    'SubnetMask': '255.255.255.0',
    'DNSType': 'DNS Proxy',
    'DNSServer1': '',
    'DNSServer2': '',
    'IPv6_IdentifierType': 'EUI64',
    'IPv6_LinkLocalAddressType': 'EUI64',
  };

  /// Parental control profiles + master switch.
  List<Map<String, dynamic>> parental = [
    {'Index': 1, 'pcpName': 'Kids-Night', 'pcpEnable': 1, 'MACAddressList': '58:CB:52:19:E2:61', 'Days': 'Mon,Tue', 'TimeRangeList': '23:00-23:59'},
  ];
  String parentalMaster = '0';
  int deviceBytes = 0;

  /// QoS → General. Field names are an assumption; the driver discovers the
  /// downstream field by name ("…Down…").
  Map<String, dynamic> qos = {'Enable': false, 'UpRate': 0, 'DownRate': 0, 'TrafficPriority': 'auto'};
  int rxBytes = 123456789012;
  int txBytes = 9876543210;

  int get port => _server.port;

  Future<void> start() async {
    final rnd = FortunaRandom()
      ..seed(KeyParameter(Uint8List.fromList(List.generate(32, (_) => Random.secure().nextInt(256)))));
    final gen = RSAKeyGenerator()
      ..init(ParametersWithRandom(RSAKeyGeneratorParameters(BigInt.from(65537), 1024, 64), rnd));
    final pair = gen.generateKeyPair();
    _priv = pair.privateKey as RSAPrivateKey;
    _publicPem = _spkiPem(pair.publicKey as RSAPublicKey);

    if (https) {
      // Throw-away self-signed certificate, generated per run (nothing secret
      // is stored in the repository).
      final dir = await Directory.systemTemp.createTemp('fake_zyxel');
      final cert = '${dir.path}/cert.pem', key = '${dir.path}/key.pem';
      final gen = await Process.run('openssl', [
        'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-keyout', key, '-out', cert,
        '-days', '1', '-subj', '/CN=fake-router',
      ]);
      if (gen.exitCode != 0) throw StateError('openssl is needed for HTTPS router tests: ${gen.stderr}');
      final ctx = SecurityContext()
        ..useCertificateChain(cert)
        ..usePrivateKey(key);
      _server = await HttpServer.bindSecure(InternetAddress.loopbackIPv4, 0, ctx);
    } else {
      _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    }
    _server.listen(_handle, onError: (_) {});
  }

  Future<void> stop() => _server.close(force: true);

  /// Simulates the router dropping all sessions (idle timeout / reboot).
  void expireSessions() => _sessions.clear();

  /// Simulates someone else (e.g. a browser) holding the admin session.
  void occupyByOtherClient() => _sessions['browser'] = (csrf: '1', aesKey: null);

  static String _spkiPem(RSAPublicKey k) {
    final pkcs1 = ASN1Sequence(elements: [ASN1Integer(k.modulus), ASN1Integer(k.exponent)])..encode();
    final algo = ASN1Sequence(elements: [
      ASN1ObjectIdentifier.fromIdentifierString('1.2.840.113549.1.1.1'),
      ASN1Null(),
    ]);
    final spki = ASN1Sequence(elements: [algo, ASN1BitString(stringValues: pkcs1.encodedBytes!)]);
    final b64 = base64Encode(spki.encode());
    final lines = [for (var i = 0; i < b64.length; i += 64) b64.substring(i, min(i + 64, b64.length))];
    return '-----BEGIN PUBLIC KEY-----\n${lines.join('\n')}\n-----END PUBLIC KEY-----';
  }

  Uint8List _rsaDecrypt(String b64) {
    final e = enc.Encrypter(enc.RSA(privateKey: _priv, encoding: enc.RSAEncoding.PKCS1));
    return base64Decode(e.decrypt(enc.Encrypted.fromBase64(b64)));
  }

  static Map<String, dynamic> _aesDecrypt(Uint8List key, Map body) {
    final iv = enc.IV(Uint8List.fromList(base64Decode(body['iv'] as String).sublist(0, 16)));
    final clear = enc.Encrypter(enc.AES(enc.Key(key), mode: enc.AESMode.cbc))
        .decrypt64(body['content'] as String, iv: iv);
    return jsonDecode(clear) as Map<String, dynamic>;
  }

  static Map<String, String> _aesEncrypt(Uint8List key, Object payload) {
    final ivFull = enc.IV.fromSecureRandom(32);
    final iv = enc.IV(Uint8List.fromList(ivFull.bytes.sublist(0, 16)));
    final content =
        enc.Encrypter(enc.AES(enc.Key(key), mode: enc.AESMode.cbc)).encrypt(jsonEncode(payload), iv: iv);
    return {'content': content.base64, 'iv': ivFull.base64};
  }

  static String _newKey() {
    const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
    final r = Random.secure();
    return List.generate(48, (_) => chars[r.nextInt(chars.length)]).join();
  }

  Future<void> _handle(HttpRequest req) async {
    final path = req.uri.path;
    final oid = req.uri.queryParameters['oid'];
    requests.add('${req.method} $path${oid == null ? '' : '?oid=$oid'}');
    final raw = await utf8.decodeStream(req);
    final res = req.response;

    Future<void> json(Object body, {int status = 200}) async {
      res
        ..statusCode = status
        ..headers.contentType = ContentType.json
        ..write(jsonEncode(body));
      await res.close();
    }

    if (path == '/') {
      res.headers.contentType = ContentType.html;
      res.write('<html><title>Zyxel VMG3625-T50B</title></html>');
      return res.close();
    }
    if (path == '/getRSAPublickKey') {
      if (!encrypted) return json({'result': 'ZCFG_NOT_FOUND'}, status: 404);
      return json({'RSAPublicKey': _publicPem});
    }

    final cookie = req.cookies.where((c) => c.name == 'Session').map((c) => c.value).firstOrNull;

    if (path == '/UserLogin' && req.method == 'POST') {
      var body = jsonDecode(raw) as Map<String, dynamic>;
      Uint8List? aesKey;
      if (encrypted) {
        aesKey = _rsaDecrypt(body['key'] as String);
        body = _aesDecrypt(aesKey, body);
      }
      final pass = utf8.decode(base64Decode(body['Input_Passwd'] as String));
      Object reply;
      var status = 200;
      if (body['Input_Account'] != username || pass != password) {
        status = 401;
        reply = {'result': 'Invalid Username or Password'};
      } else if (_sessions.keys.any((c) => c != cookie)) {
        status = 401;
        reply = {'result': 'Duplicated login'};
      } else {
        loginCount++;
        if (cookie != null) _sessions.remove(cookie);
        final newCookie = 'sess${Random().nextInt(1 << 30)}';
        final csrf = _newKey();
        _sessions[newCookie] = (csrf: csrf, aesKey: aesKey);
        res.headers.add('Set-Cookie', 'Session=$newCookie; Path=/; Secure; HttpOnly');
        reply = {'result': 'ZCFG_SUCCESS', 'sessionkey': csrf, 'loginAccount': username, 'loginLevel': 'medium'};
      }
      return json(aesKey == null ? reply : _aesEncrypt(aesKey, reply), status: status);
    }

    final session = cookie == null ? null : _sessions[cookie];
    if (session == null) return json({'result': 'Invalid Session'}, status: 401);

    Future<void> reply(Object body, {int status = 200}) =>
        json(session.aesKey == null ? body : _aesEncrypt(session.aesKey!, body), status: status);
    Map<String, dynamic> payload() {
      final b = jsonDecode(raw) as Map<String, dynamic>;
      return session.aesKey == null ? b : _aesDecrypt(session.aesKey!, b);
    }

    final isWrite = req.method != 'GET';
    String? nextKey;
    if (isWrite) {
      if (req.headers.value('CSRFToken') != session.csrf) {
        staleCsrfRejections++;
        return json({'result': 'bad csrf'}, status: 403);
      }
      nextKey = _newKey();
      _sessions[cookie!] = (csrf: nextKey, aesKey: session.aesKey);
    }
    Future<void> writeOk([Map<String, dynamic> extra = const {}]) =>
        reply({'result': 'ZCFG_SUCCESS', 'sessionkey': nextKey, ...extra});

    if (path == '/cgi-bin/UserLogout') {
      logoutCount++;
      _sessions.remove(cookie);
      return writeOk();
    }
    if (path == '/cgi-bin/Reboot') {
      rebootCount++;
      return json({'result': 'ZCFG_SUCCESS'});
    }
    if (path != '/cgi-bin/DAL') return json({'result': 'not found'}, status: 404);

    Future<void> ok(Object obj) => reply({'result': 'ZCFG_SUCCESS', 'Object': obj});

    switch ((req.method, oid)) {
      case ('GET', 'cardpage_status'):
        return ok([
          {
            'DeviceInfo': {'ModelName': 'VMG3625-T50B', 'SoftwareVersion': 'V5.50(ABPM.9)C0', 'UpTime': 93784, 'SerialNumber': 'S000H11223344'},
            'WanType': 'VDSL',
            'WanRate_RX': 41234,
            'WanRate_TX': 1820,
            'DslChannelInfo': [
              {'Status': 'Up', 'DownstreamCurrRate': 51200, 'UpstreamCurrRate': 10240, 'LinkEncapsulationUsed': 'G.993.2_Annex_K_PTM'},
            ],
            'WanLanInfo': [
              {'Status': 'Up', 'X_ZYXEL_SrvName': 'LAN', 'Type': 'LAN', 'IPv4Address': [{'IPAddress': '192.168.1.1'}]},
              {'Status': 'Up', 'X_ZYXEL_SrvName': 'IPTV', 'IPv4Address': [{'IPAddress': '10.1.1.1'}]},
              {'Status': 'Up', 'LinkType': 'PTM', 'X_ZYXEL_SrvName': 'WAN_INTERNET', 'Encapsulation': 'PPPoE', 'DefaultGateway': '41.235.0.1', 'IPv4Address': [{'IPAddress': '41.235.18.77'}], 'pppoeConnectionUpTime': 8000},
            ],
            'WiFiInfo': [
              {'SSID': 'WE_ABC123', 'Enable': 1, 'Channel': 6, 'OperatingStandards': 'b,g,n', 'ModeEnabled': 'WPA2-Personal', 'wifiPassword': '11223344'},
              {'SSID': 'WE_ABC123_5G', 'Enable': true, 'Channel': 36, 'OperatingStandards': 'a,n,ac', 'ModeEnabled': 'WPA2-Personal', 'wifiPassword': '11223344'},
            ],
          }
        ]);
      case ('GET', 'Traffic_Status'):
        return ok([
          {
            'ipIfaceSt': [
              // LAN bridge carries more bytes than WAN: must NOT be picked.
              {'Name': 'LAN', 'X_ZYXEL_IfName': 'br0', 'BytesReceived': '999999999999', 'BytesSent': '999999999999'},
            ],
            'pppIfaceSt': [
              {'X_ZYXEL_IfName': 'ppp0.1', 'BytesReceived': '$rxBytes', 'BytesSent': '$txBytes'},
            ],
          }
        ]);
      case ('GET', 'lanhosts'):
        return ok([
          {
            'wanInfo': {'wanStatus': 'Up'},
            'lanhosts': [
              {'HostName': 'galaxy', 'curHostName': 'Galaxy-S25', 'IPAddress': '192.168.1.34', 'PhysAddress': 'a4:c3:f0:12:9b:01', 'X_ZYXEL_ConnectionType': 'Wi-Fi', 'Layer1Interface': 'Device.WiFi.SSID.5', 'X_ZYXEL_OperatingStandard': 'ac', 'X_ZYXEL_SignalStrength': 4, 'X_ZYXEL_BytesSent': 5000000000 + deviceBytes, 'X_ZYXEL_BytesReceived': 300000000, 'Active': true},
              {'HostName': '', 'IPAddress': '192.168.1.10', 'PhysAddress': '00:1b:21:3c:8d:50', 'X_ZYXEL_ConnectionType': 'Ethernet', 'Layer1Interface': 'Device.Ethernet.Interface.2', 'X_ZYXEL_SignalStrength': 0, 'Active': 1},
              {'HostName': 'TV', 'IPAddress': '192.168.1.40', 'PhysAddress': '7c:1c:68:aa:10:3e', 'X_ZYXEL_ConnectionType': 'Wi-Fi', 'Layer1Interface': 'WiFi.SSID.1', 'X_ZYXEL_OperatingStandard': 'n', 'Active': false},
            ],
          }
        ]);
      case ('GET', 'wlan'):
        return ok(wlanAvailable ? [wlan] : []);
      case ('PUT', 'wlan'):
        wlan = payload();
        return writeOk();
      case ('GET', 'lan'):
        return ok([lan]);
      case ('PUT', 'lan'):
        final p = payload();
        if (p.containsKey('IPv6_IdentifierType')) {
          return reply({'result': 'ZCFG_INVALID_PARAM_VALUE', 'ReplyMsg': 'IPv6_IdentifierType', 'sessionkey': nextKey});
        }
        lan = {...lan, ...p};
        return writeOk();
      case ('GET', 'paren_ctl'):
        return ok(parental);
      case ('POST', 'paren_ctl'):
        final p = payload();
        if (p['Days'] is! List) {
          return reply({'result': 'ZCFG_INVALID_PARAM_VALUE', 'ReplyMsg': 'Days', 'sessionkey': nextKey});
        }
        final next = parental.fold<int>(0, (m, e) => max(m, e['Index'] as int)) + 1;
        parental.add({...p, 'Index': next, 'Days': (p['Days'] as List).join(',')});
        return writeOk();
      case ('PUT', 'paren_ctl'):
        final p = payload();
        if (p.containsKey('PrentalCtlEnable') && p.length == 1) {
          parentalMaster = '${p['PrentalCtlEnable']}';
          return writeOk();
        }
        parental = [for (final e in parental) e['Index'] == p['Index'] ? {...p, 'Days': (p['Days'] as List).join(',')} : e];
        return writeOk();
      case ('DELETE', 'paren_ctl'):
        final idx = int.parse(req.uri.queryParameters['Index']!);
        parental.removeWhere((e) => e['Index'] == idx);
        return writeOk();
      case ('GET', 'qos'):
        return ok([qos]);
      case ('PUT', 'qos'):
        qos = payload();
        return writeOk();
      case ('POST', 'qos_shaper'):
        return reply({'result': 'ZCFG_INVALID_PARAM_VALUE', 'ReplyMsg': 'Interface', 'sessionkey': nextKey});
      default:
        // Unknown oids answer "success" with nothing in them.
        return isWrite ? writeOk() : ok([]);
    }
  }
}
