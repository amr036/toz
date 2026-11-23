import 'dart:math';

import '../../features/usage/domain/usage_models.dart';

/// Wraps text in a Unicode LTR isolate so "2.4 GHz" / "12 Mbps" don't get
/// reordered inside Arabic (RTL) sentences.
String ltr(String s) => '\u2066$s\u2069';

/// "12.3 GB" (bidi-safe).
String gbLabel(num bytes, {int decimals = 1}) => ltr('${formatGb(bytes, decimals: decimals)} GB');

String formatGb(num bytes, {int decimals = 1}) => bytesToGb(bytes).toStringAsFixed(decimals);

String formatBytes(num bytes) {
  if (bytes >= bytesPerGb) return '${(bytes / bytesPerGb).toStringAsFixed(2)} GB';
  if (bytes >= 1000 * 1000) return '${(bytes / 1e6).toStringAsFixed(1)} MB';
  if (bytes >= 1000) return '${(bytes / 1e3).toStringAsFixed(0)} KB';
  return '${bytes.round()} B';
}

/// bits/s → "12.4 Mbps"
String formatRate(double bitsPerSecond) {
  final v = max(0.0, bitsPerSecond);
  if (v >= 1e6) return ltr('${(v / 1e6).toStringAsFixed(v >= 1e8 ? 0 : 1)} Mbps');
  if (v >= 1e3) return ltr('${(v / 1e3).toStringAsFixed(0)} Kbps');
  return ltr('${v.toStringAsFixed(0)} bps');
}

String formatKbpsLine(int? kbps) => kbps == null ? '—' : (kbps / 1000).toStringAsFixed(1);

String formatUptime(Duration? d, {required bool arabic}) {
  if (d == null) return '—';
  final days = d.inDays;
  final h = d.inHours % 24;
  final m = d.inMinutes % 60;
  return arabic ? '$daysي $hس $mد' : '${days}d ${h}h ${m}m';
}

String formatMbps(double mbps) =>
    ltr(mbps == mbps.roundToDouble() ? '${mbps.toInt()} Mbps' : '${mbps.toStringAsFixed(1)} Mbps');
