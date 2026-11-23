import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:material_ui/material_ui.dart' show Locale;
import 'package:shared_preferences/shared_preferences.dart';

import '../../features/usage/domain/usage_models.dart';
import '../l10n/app_strings.dart';
import '../utils/formatters.dart';

/// Quota threshold notifications (75 / 90 / 100 %), shown once per level per
/// billing cycle. Works from the app and from the background sync isolate.
class UsageAlerts {
  UsageAlerts._();

  static final _plugin = FlutterLocalNotificationsPlugin();
  static bool _initialized = false;

  static bool get _supported => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  static const _channel = AndroidNotificationDetails(
    'quota_alerts',
    'Quota alerts',
    channelDescription: 'Warnings when internet usage reaches 75%, 90% and 100% of the quota',
    importance: Importance.high,
    priority: Priority.high,
  );

  static Future<void> init() async {
    if (!_supported || _initialized) return;
    await _plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      ),
    );
    _initialized = true;
  }

  /// Android 13+ runtime permission. Call from the UI isolate only.
  static Future<void> requestPermission() async {
    if (!_supported) return;
    await init();
    await _plugin
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
        ?.requestNotificationsPermission();
  }

  static int _levelOf(UsageWarning w) => switch (w) {
        UsageWarning.none => 0,
        UsageWarning.p75 => 75,
        UsageWarning.p90 => 90,
        UsageWarning.p100 => 100,
      };

  /// Notifies if [stats] crossed a level not yet announced this cycle.
  /// Returns the level notified, or null.
  static Future<int?> check(
    SharedPreferences prefs,
    UsageStats stats, {
    required bool demo,
  }) async {
    final level = _levelOf(stats.warning);
    final key = '${demo ? 'demo' : 'real'}.alerted.${stats.cycle.key}';
    final already = prefs.getInt(key) ?? 0;
    if (level <= already) return null;
    await prefs.setInt(key, level);
    if (!_supported) return level;

    await init();
    final locale = Locale(prefs.getString('locale') ?? 'ar');
    String t(String k) => AppStrings.of(locale, k);
    final title = t(level >= 100 ? 'warn100' : (level >= 90 ? 'warn90' : 'warn75'));
    final body = '${t('used')}: ${gbLabel(stats.usedBytes)} / ${gbLabel(stats.quotaBytes, decimals: 0)}'
        ' · ${t('remaining')}: ${gbLabel(stats.remainingBytes)}';
    try {
      await _plugin.show(
        id: 100 + level,
        title: title,
        body: body,
        notificationDetails: const NotificationDetails(android: _channel),
      );
    } catch (e) {
      debugPrint('[UsageAlerts] show failed: $e');
    }
    return level;
  }
}
