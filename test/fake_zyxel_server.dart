import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:encrypt/encrypt.dart' as enc;
import 'package:pointycastle/asn1.dart';
import 'package:pointycastle/export.dart';

/// In-process imitation of a ZYXEL VMG3625-T50B web API (V5.50-style), used
/// to exercise ZyxelVmg3625Driver end to end: RSA key exchange, AES-CBC
/// payloads, session cookie + CSRFToken, DAL objects, session expiry.
class FakeZyxelServer {
  FakeZyxelServer({this.encrypted = true, this.username = 'admin', this.password = 'S3cret!'});

  final bool encrypted;
  final String username;
  final String password;

  late HttpServer _server;
  late RSAPrivateKey _priv;
  late String _publicPem;

  /// session cookie → (csrf key, aes key)
  final _sessions = <String, ({String csrf, Uint8List? aesKey})>{};
  int loginCount = 0;
  int logoutCount = 0;
  final requests = <String>[];

  // Mutable router state.
  Map<String, dynamic> wlan = {
    'Index': 1,
    'wlEnable': true,
    'SSID': 'ZYXEL_HOME',
    'wpaPsk': 'oldpassword',
    'MaxAssociatedDevices': 32,
    'TransmitPower': 100,
  };
  Map<String, dynamic> lan = {'Index': 1, 'DNSType': 'DNS Proxy', 'DNSServer1': '', 'DNSServer2': ''};
  List<Map<String, dynamic>> shaper = [
    {'Index': 1, 'Enable': false, 'Interface': 'WAN_VDSL', 'ShapingRate': 0},
    {'Index': 2, 'Enable': false, 'Interface': 'WiFi_2.4G_5G', 'ShapingRate': 0},
  ];
  bool qosEnabled = false;
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

    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen(_handle);
  }

  Future<void> stop() => _server.close(force: true);

  /// Simulates the router dropping all sessions (timeout / reboot).
  void expireSessions() => _sessions.clear();

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
    final aesKeyB64 = e.decrypt(enc.Encrypted.fromBase64(b64));
    return base64Decode(aesKeyB64);
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
      res.write('<html><title>ZyXEL VMG3625-T50B</title></html>');
      return res.close();
    }
    if (path == '/getRSAPublickKey') {
      if (!encrypted) return json({'result': 'ZCFG_NOT_FOUND'}, status: 404);
      return json({'RSAPublicKey': _publicPem});
    }
    if (path == '/UserLogin' && req.method == 'POST') {
      var body = jsonDecode(raw) as Map<String, dynamic>;
      Uint8List? aesKey;
      if (encrypted) {
        aesKey = _rsaDecrypt(body['key'] as String);
        body = _aesDecrypt(aesKey, body);
      }
      final pass = utf8.decode(base64Decode(body['Input_Passwd'] as String));
      Object reply;
      if (body['Input_Account'] == username && pass == password) {
        loginCount++;
        final cookie = 'sess${Random().nextInt(1 << 30)}';
        final csrf = Random().nextInt(1 << 30); // numeric, like the real router
        _sessions[cookie] = (csrf: '$csrf', aesKey: aesKey);
        res.headers.add('Set-Cookie', 'Session=$cookie; Path=/; HttpOnly');
        reply = {'result': 'ZCFG_SUCCESS', 'sessionkey': csrf, 'ThemeColor': 'blue'};
      } else {
        reply = {'result': 'Invalid Username or Password'};
      }
      return json(aesKey == null ? reply : _aesEncrypt(aesKey, reply));
    }

    // Everything below needs a valid session.
    final cookie = req.cookies.where((c) => c.name == 'Session').map((c) => c.value).firstOrNull;
    final session = cookie == null ? null : _sessions[cookie];
    if (session == null || req.headers.value('CSRFToken') != session.csrf) {
      return json({'result': 'Invalid Session'}, status: 401);
    }
    Future<void> reply(Object body) =>
        json(session.aesKey == null ? body : _aesEncrypt(session.aesKey!, body));
    Map<String, dynamic> payload() {
      final b = jsonDecode(raw) as Map<String, dynamic>;
      return session.aesKey == null ? b : _aesDecrypt(session.aesKey!, b);
    }

    if (path == '/cgi-bin/UserLogout') {
      logoutCount++;
      _sessions.remove(cookie);
      return reply({'result': 'ZCFG_SUCCESS'});
    }
    if (path == '/cgi-bin/Reboot') return reply({'result': 'ZCFG_SUCCESS'});
    if (path != '/cgi-bin/DAL') return json({'result': 'not found'}, status: 404);

    Future<void> ok(Object obj) => reply({'result': 'ZCFG_SUCCESS', 'Object': obj});

    switch ((req.method, oid)) {
      case ('GET', 'cardpage_status'):
        return ok([
          {
            'DeviceInfo': {'ModelName': 'VMG3625-T50B', 'SoftwareVersion': 'V5.50(ABPM.9)C0', 'UpTime': 93784},
            'DslChannelInfo': [
              {'Status': 'Up', 'DownstreamCurrRate': 51200, 'UpstreamCurrRate': 10240, 'LinkEncapsulationUsed': 'G.993.2_Annex_K_PTM', 'StandardUsed': 'VDSL2'},
            ],
            'WanLanInfo': [
              {'Name': 'LAN', 'Type': 'LAN', 'Status': 'Up', 'IPAddress': '192.168.1.1'},
              {'Name': 'IPTV', 'Status': 'Up', 'IPAddress': '10.1.1.1'},
              {'Name': 'WAN_VDSL', 'Status': 'Up', 'IPAddress': '41.235.18.77', 'Encapsulation': 'PPPoE'},
            ],
          }
        ]);
      case ('GET', 'Traffic_Status'):
        return ok([
          {
            'ipIfaceSt': [
              // LAN bridge carries more bytes than WAN: must NOT be picked.
              {'Name': 'LAN', 'X_ZYXEL_IfName': 'br0', 'BytesReceived': '999999999999', 'BytesSent': '999999999999'},
              {'Name': 'WAN_VDSL', 'X_ZYXEL_IfName': 'ppp0.1', 'BytesReceived': '$rxBytes', 'BytesSent': '$txBytes'},
            ],
          }
        ]);
      case ('GET', 'lanhosts'):
        return ok([
          {
            'lanhosts': [
              {'HostName': 'Galaxy', 'IPAddress': '192.168.1.34', 'PhysAddress': 'a4:c3:f0:12:9b:01', 'X_ZYXEL_ConnectionType': 'Wi-Fi', 'X_ZYXEL_WiFiBand': '5GHz', 'X_ZYXEL_SignalStrength': -51, 'Active': true},
              {'HostName': '', 'IPAddress': '192.168.1.10', 'PhysAddress': '00:1b:21:3c:8d:50', 'X_ZYXEL_ConnectionType': 'Ethernet', 'Active': true},
              {'HostName': 'TV', 'IPAddress': '192.168.1.40', 'PhysAddress': '7c:1c:68:aa:10:3e', 'X_ZYXEL_ConnectionType': 'Wi-Fi', 'X_ZYXEL_WiFiBand': '2.4GHz', 'Active': false},
            ],
          }
        ]);
      case ('GET', 'wlan'):
        return ok([wlan]);
      case ('PUT', 'wlan'):
        wlan = payload();
        return reply({'result': 'ZCFG_SUCCESS'});
      case ('GET', 'lan'):
        return ok([lan]);
      case ('PUT', 'lan'):
        lan = payload();
        return reply({'result': 'ZCFG_SUCCESS'});
      case ('GET', 'qos_shaper'):
        return ok(shaper);
      case ('PUT', 'qos_shaper'):
        final p = payload();
        shaper = [for (final s in shaper) s['Index'] == p['Index'] ? p : s];
        return reply({'result': 'ZCFG_SUCCESS'});
      case ('PUT', 'qos'):
        qosEnabled = payload()['Enable'] == true;
        return reply({'result': 'ZCFG_SUCCESS'});
      default:
        return reply({'result': 'ZCFG_NO_SUCH_OBJECT'});
    }
  }
}
