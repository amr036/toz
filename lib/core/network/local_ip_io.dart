import 'dart:io';

/// Private IPv4 of this device, preferring the gateway's /24 and Wi-Fi.
Future<String?> findLanIp({String? preferSubnetOf}) async {
  try {
    final ifaces = await NetworkInterface.list(type: InternetAddressType.IPv4);
    final candidates = <(String name, String ip)>[
      for (final i in ifaces)
        for (final a in i.addresses)
          if (_isPrivate(a.address)) (i.name, a.address),
    ];
    if (candidates.isEmpty) return null;
    if (preferSubnetOf != null) {
      final g = preferSubnetOf.split(':').first.split('.').take(3).join('.');
      for (final c in candidates) {
        if (c.$2.startsWith('$g.')) return c.$2;
      }
    }
    for (final c in candidates) {
      if (c.$1.startsWith('wlan') || c.$1.startsWith('wl')) return c.$2;
    }
    return candidates.first.$2;
  } catch (_) {
    return null;
  }
}

bool _isPrivate(String ip) =>
    ip.startsWith('192.168.') ||
    ip.startsWith('10.') ||
    RegExp(r'^172\.(1[6-9]|2\d|3[01])\.').hasMatch(ip);
