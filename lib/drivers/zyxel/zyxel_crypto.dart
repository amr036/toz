import 'dart:convert';
import 'dart:typed_data';

import 'package:encrypt/encrypt.dart';
import 'package:pointycastle/asymmetric/api.dart' show RSAPublicKey;

/// Payload codec for ZYXEL firmwares that encrypt the web-GUI traffic
/// (seen on VMG3625-T50B / VMG8825-T50 V5.50+ builds).
///
/// Scheme used by the stock web UI JavaScript:
///  1. GET /getRSAPublickKey  → `{"RSAPublicKey": "-----BEGIN PUBLIC KEY-----..."}`
///  2. Client picks a random 32-byte AES key and 32-byte IV (first 16 bytes used).
///  3. Request body = `{"content": b64(AES-CBC(json)), "key": b64(RSA-PKCS1(b64(aesKey))), "iv": b64(iv)}`
///  4. Responses come back as `{"content": ..., "iv": ...}` encrypted with the same AES key.
///
/// If your firmware differs, compare against `/js/util.js` / `AesKeyEncrypt`
/// in the router's own JavaScript (DevTools → Sources).
class ZyxelCrypto {
  ZyxelCrypto(String publicKeyPem)
      : _rsa = Encrypter(RSA(
          publicKey: RSAKeyParser().parse(_normalizePem(publicKeyPem)) as RSAPublicKey,
          encoding: RSAEncoding.PKCS1,
        )),
        _aesKey = Key.fromSecureRandom(32),
        _ivFull = IV.fromSecureRandom(32);

  final Encrypter _rsa;
  final Key _aesKey;
  final IV _ivFull;

  Encrypter get _aes => Encrypter(AES(_aesKey, mode: AESMode.cbc));

  IV get _iv16 => IV(Uint8List.fromList(_ivFull.bytes.sublist(0, 16)));

  Map<String, String> encrypt(Object payload) {
    final jsonStr = jsonEncode(payload);
    return {
      'content': _aes.encrypt(jsonStr, iv: _iv16).base64,
      'key': _rsa.encrypt(base64Encode(_aesKey.bytes)).base64,
      'iv': _ivFull.base64,
    };
  }

  /// Returns decoded JSON. Passes through responses that aren't encrypted.
  dynamic decrypt(dynamic body) {
    if (body is Map && body['content'] is String && body['iv'] is String) {
      final ivBytes = base64Decode(body['iv'] as String);
      final iv = IV(Uint8List.fromList(ivBytes.sublist(0, 16)));
      final clear = _aes.decrypt64(body['content'] as String, iv: iv);
      return jsonDecode(clear);
    }
    return body;
  }

  static String _normalizePem(String pem) {
    final trimmed = pem.trim();
    if (trimmed.contains('BEGIN')) return trimmed;
    return '-----BEGIN PUBLIC KEY-----\n$trimmed\n-----END PUBLIC KEY-----';
  }
}
