import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'local_ip_stub.dart' if (dart.library.io) 'local_ip_io.dart';

/// What the phone knows about its own connection to the home network.
class LocalNetworkInfo {
  const LocalNetworkInfo({this.phoneIp, this.boundToWifi});

  /// This phone's IPv4 address on the LAN (e.g. 192.168.1.37), if any.
  final String? phoneIp;

  /// Android: app traffic is pinned to the Wi-Fi network (see
  /// NetPulseApplication.kt). Null where not applicable.
  final bool? boundToWifi;

  /// True when the phone has an address in the same /24 as [gatewayIp].
  bool sameSubnetAs(String gatewayIp) {
    final ip = phoneIp;
    if (ip == null) return false;
    final g = gatewayIp.split(':').first.split('.');
    final p = ip.split('.');
    return g.length == 4 && p.length == 4 && g[0] == p[0] && g[1] == p[1] && g[2] == p[2];
  }

  String describe() => 'phone IP ${phoneIp ?? 'none'}'
      '${boundToWifi == null ? '' : ', bound to Wi-Fi: ${boundToWifi! ? 'yes' : 'no'}'}';
}

const _channel = MethodChannel('netpulse/network');

Future<LocalNetworkInfo> localNetworkInfo({String? gatewayIp}) async {
  if (kIsWeb) return const LocalNetworkInfo();
  bool? bound;
  if (defaultTargetPlatform == TargetPlatform.android) {
    try {
      final m = await _channel.invokeMapMethod<String, dynamic>('status');
      bound = m?['boundToWifi'] as bool?;
    } catch (_) {
      // Background isolate / tests: no activity channel.
    }
  }
  return LocalNetworkInfo(phoneIp: await findLanIp(preferSubnetOf: gatewayIp), boundToWifi: bound);
}
