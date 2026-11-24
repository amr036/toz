import 'package:material_ui/material_ui.dart';

/// Lightweight bilingual string table (English LTR / Arabic RTL).
///
/// Kept as plain maps instead of ARB + codegen so the project builds with a
/// bare `flutter run` and strings are easy to edit. Usage: `context.tr('key')`.
class AppStrings {
  static const supportedLocales = [Locale('ar'), Locale('en')];

  static const Map<String, Map<String, String>> _t = {
    'appName': {'en': 'NetPulse', 'ar': 'نت بلس'},
    'appFullName': {'en': 'NetPulse Router Manager', 'ar': 'نت بلس لإدارة الراوتر'},

    // Navigation
    'navDashboard': {'en': 'Dashboard', 'ar': 'الرئيسية'},
    'navUsage': {'en': 'Usage', 'ar': 'الاستهلاك'},
    'navWifi': {'en': 'Wi-Fi', 'ar': 'الواي فاي'},
    'navDevices': {'en': 'Devices', 'ar': 'الأجهزة'},

    // Setup
    'setupTitle': {'en': 'Connect to your router', 'ar': 'الاتصال بالراوتر'},
    'setupSubtitle': {
      'en': 'Credentials are encrypted on this device and only sent to your local gateway.',
      'ar': 'يتم تشفير بيانات الدخول على جهازك ولا تُرسل إلا إلى الراوتر المحلي فقط.',
    },
    'routerModel': {'en': 'Router model', 'ar': 'موديل الراوتر'},
    'comingSoon': {'en': 'coming soon', 'ar': 'قريباً'},
    'gatewayIp': {'en': 'Gateway IP', 'ar': 'عنوان الراوتر (IP)'},
    'username': {'en': 'Username', 'ar': 'اسم المستخدم'},
    'password': {'en': 'Password', 'ar': 'كلمة المرور'},
    'useHttps': {'en': 'Use HTTPS', 'ar': 'استخدام HTTPS'},
    'demoMode': {'en': 'Demo mode (simulated router)', 'ar': 'وضع التجربة (راوتر افتراضي)'},
    'demoModeHint': {
      'en': 'Use this in cloud previews or to explore the app without hardware. Login: admin / demo',
      'ar': 'استخدمه للتجربة بدون راوتر حقيقي. الدخول: admin / demo',
    },
    'connect': {'en': 'Connect', 'ar': 'اتصال'},
    'connecting': {'en': 'Connecting…', 'ar': 'جارٍ الاتصال…'},
    'required': {'en': 'Required', 'ar': 'مطلوب'},
    'invalidIp': {'en': 'Enter a valid IP / host', 'ar': 'أدخل عنوان IP صحيح'},
    'routerSettings': {'en': 'Router connection', 'ar': 'إعدادات الاتصال بالراوتر'},
    'disconnect': {'en': 'Disconnect', 'ar': 'قطع الاتصال'},

    // Errors
    'err_unreachable': {
      'en': 'Router not reachable. Are you on its Wi-Fi? Check the gateway IP.',
      'ar': 'لا يمكن الوصول للراوتر. تأكد أنك متصل بالواي فاي الخاص به وراجع عنوان IP.',
    },
    'err_notOnLan': {
      'en': "This phone isn't on the router's network. Connect to the home Wi-Fi (not mobile data) and try again.",
      'ar': 'الموبايل غير متصل بشبكة الراوتر. اتصل بواي فاي البيت (وليس بيانات الموبايل) ثم أعد المحاولة.',
    },
    'err_invalidCredentials': {'en': 'Wrong username or password.', 'ar': 'اسم المستخدم أو كلمة المرور غير صحيحة.'},
    'err_sessionExpired': {'en': 'Session expired, reconnecting…', 'ar': 'انتهت الجلسة، جارٍ إعادة الاتصال…'},
    'err_tooManySessions': {
      'en': 'The router allows only one admin session. Log out of the router page in your browser (or wait 5 minutes) and retry.',
      'ar': 'الراوتر يسمح بجلسة إدارة واحدة فقط. سجّل الخروج من صفحة الراوتر في المتصفح (أو انتظر ٥ دقائق) ثم أعد المحاولة.',
    },
    'err_lockedOut': {
      'en': 'The router locked the admin account after failed logins. Wait a minute, check the password, and try again.',
      'ar': 'الراوتر قفل حساب الإدارة مؤقتاً بعد محاولات دخول خاطئة. انتظر دقيقة وتأكد من كلمة المرور ثم أعد المحاولة.',
    },
    'err_unsupportedFirmware': {'en': 'This firmware version is not supported yet.', 'ar': 'إصدار السوفت وير غير مدعوم حالياً.'},
    'err_notSupported': {'en': 'Not supported by this router / firmware.', 'ar': 'غير مدعوم في هذا الراوتر أو السوفت وير.'},
    'err_unexpectedResponse': {'en': 'Unexpected response from router.', 'ar': 'استجابة غير متوقعة من الراوتر.'},
    'err_generic': {'en': 'Something went wrong.', 'ar': 'حدث خطأ ما.'},

    // Dashboard
    'connected': {'en': 'Connected', 'ar': 'متصل'},
    'disconnected': {'en': 'Disconnected', 'ar': 'غير متصل'},
    'internet': {'en': 'Internet', 'ar': 'الإنترنت'},
    'model': {'en': 'Model', 'ar': 'الموديل'},
    'firmware': {'en': 'Firmware', 'ar': 'السوفت وير'},
    'wanIp': {'en': 'WAN IP', 'ar': 'IP الخارجي'},
    'line': {'en': 'Line', 'ar': 'الخط'},
    'lineSync': {'en': 'Line sync', 'ar': 'سرعة الخط'},
    'uptime': {'en': 'Uptime', 'ar': 'مدة التشغيل'},
    'download': {'en': 'Download', 'ar': 'تحميل'},
    'upload': {'en': 'Upload', 'ar': 'رفع'},
    'liveRate': {'en': 'Live rate', 'ar': 'السرعة الحالية'},
    'quickActions': {'en': 'Quick actions', 'ar': 'إجراءات سريعة'},
    'reboot': {'en': 'Reboot router', 'ar': 'إعادة تشغيل الراوتر'},
    'rebootConfirm': {
      'en': 'The internet will drop for ~2 minutes. Reboot now?',
      'ar': 'سينقطع الإنترنت لمدة دقيقتين تقريباً. إعادة التشغيل الآن؟',
    },
    'rebooting': {'en': 'Router is rebooting…', 'ar': 'جارٍ إعادة تشغيل الراوتر…'},
    'openAdmin': {'en': 'Router admin page', 'ar': 'صفحة إدارة الراوتر'},
    'syncNow': {'en': 'Sync now', 'ar': 'تحديث الآن'},
    'synced': {'en': 'Updated', 'ar': 'تم التحديث'},
    'lastUpdated': {'en': 'Last updated', 'ar': 'آخر تحديث'},
    'cancel': {'en': 'Cancel', 'ar': 'إلغاء'},
    'ok': {'en': 'OK', 'ar': 'موافق'},
    'save': {'en': 'Save', 'ar': 'حفظ'},
    'apply': {'en': 'Apply', 'ar': 'تطبيق'},
    'retry': {'en': 'Retry', 'ar': 'إعادة المحاولة'},
    'demoBadge': {'en': 'DEMO', 'ar': 'تجريبي'},
    'cycleUsage': {'en': 'This cycle', 'ar': 'هذه الدورة'},

    // Usage
    'usageTitle': {'en': 'Usage & quota', 'ar': 'الاستهلاك والباقة'},
    'used': {'en': 'Used', 'ar': 'المستهلك'},
    'remaining': {'en': 'Remaining', 'ar': 'المتبقي'},
    'of': {'en': 'of', 'ar': 'من'},
    'dailyAvg': {'en': 'Daily average', 'ar': 'متوسط يومي'},
    'projected': {'en': 'Projected at renewal', 'ar': 'المتوقع عند التجديد'},
    'daysLeftQuota': {'en': 'Quota lasts', 'ar': 'الباقة تكفي'},
    'daysLeftCycle': {'en': 'Renews in', 'ar': 'التجديد بعد'},
    'dailyBudget': {'en': 'Daily budget', 'ar': 'المسموح يومياً'},
    'days': {'en': 'days', 'ar': 'يوم'},
    'perDay': {'en': '/day', 'ar': '/يوم'},
    'never': {'en': '∞', 'ar': '∞'},
    'history': {'en': 'Daily usage', 'ar': 'الاستهلاك اليومي'},
    'last7': {'en': '7 days', 'ar': '٧ أيام'},
    'last30': {'en': '30 days', 'ar': '٣٠ يوم'},
    'quotaSettings': {'en': 'Quota & billing cycle', 'ar': 'الباقة ودورة الفاتورة'},
    'monthlyQuota': {'en': 'Monthly quota', 'ar': 'حجم الباقة الشهرية'},
    'customGb': {'en': 'Custom (GB)', 'ar': 'مخصص (جيجا)'},
    'renewalDay': {'en': 'Renewal day of month', 'ar': 'يوم التجديد في الشهر'},
    'countUpload': {'en': 'Count upload in quota', 'ar': 'احتساب الرفع ضمن الباقة'},
    'calibrate': {'en': 'Calibrate with ISP', 'ar': 'معايرة مع شركة الإنترنت'},
    'calibrateHint': {
      'en': 'Enter the used GB shown on your ISP portal / app. Daily history is kept.',
      'ar': 'أدخل الاستهلاك الظاهر في موقع أو تطبيق شركة الإنترنت بالجيجا. سيتم الاحتفاظ بالسجل اليومي.',
    },
    'usedGbIsp': {'en': 'Used GB (from ISP)', 'ar': 'المستهلك بالجيجا (من الشركة)'},
    'calibrated': {'en': 'Calibrated', 'ar': 'تمت المعايرة'},
    'clearCalibration': {'en': 'Clear calibration', 'ar': 'إلغاء المعايرة'},
    'warn75': {'en': 'You have used 75% of your quota.', 'ar': 'لقد استهلكت ٧٥٪ من الباقة.'},
    'warn90': {'en': 'Careful: 90% of your quota is used!', 'ar': 'انتبه: تم استهلاك ٩٠٪ من الباقة!'},
    'warn100': {'en': 'Quota exhausted! Speed may be reduced by your ISP.', 'ar': 'انتهت الباقة! قد تقوم الشركة بتخفيض السرعة.'},
    'willExceed': {
      'en': 'At this pace you will run out before renewal.',
      'ar': 'بهذا المعدل ستنتهي الباقة قبل موعد التجديد.',
    },
    'resetsDetected': {'en': 'Router reboots handled', 'ar': 'مرات إعادة تشغيل تم احتسابها'},
    'cycle': {'en': 'Cycle', 'ar': 'الدورة'},
    'resetHistory': {'en': 'Reset usage history', 'ar': 'مسح سجل الاستهلاك'},
    'resetHistoryConfirm': {'en': 'Delete all local usage history?', 'ar': 'حذف كل سجل الاستهلاك المحلي؟'},

    // Wi-Fi control
    'speedLimiter': {'en': 'Wi-Fi speed limiter', 'ar': 'التحكم في سرعة الواي فاي'},
    'unlimited': {'en': 'Unlimited', 'ar': 'بدون حد'},
    'custom': {'en': 'Custom', 'ar': 'مخصص'},
    'activeLimit': {'en': 'Active', 'ar': 'المفعّل'},
    'applied': {'en': 'Applied', 'ar': 'تم التطبيق'},
    'applyFailed': {'en': 'Could not apply', 'ar': 'تعذّر التطبيق'},
    'method': {'en': 'Method', 'ar': 'الطريقة'},
    'method_qosShaper': {'en': 'QoS shaper', 'ar': 'QoS Shaper'},
    'method_qosPolicer': {'en': 'QoS policer', 'ar': 'QoS Policer'},
    'method_wifiRateProfile': {'en': 'Wi-Fi rate profile', 'ar': 'ملف معدل الواي فاي'},
    'method_unsupported': {'en': 'Unsupported', 'ar': 'غير مدعوم'},
    'wifiSettings': {'en': 'Wi-Fi network', 'ar': 'شبكة الواي فاي'},
    'ssid': {'en': 'Network name (SSID)', 'ar': 'اسم الشبكة (SSID)'},
    'wifiPassword': {'en': 'Wi-Fi password', 'ar': 'كلمة سر الواي فاي'},
    'passwordMin': {'en': 'At least 8 characters', 'ar': '٨ أحرف على الأقل'},
    'maxClients': {'en': 'Max connected devices', 'ar': 'أقصى عدد للأجهزة المتصلة'},
    'txPower': {'en': 'Signal strength (transmit power)', 'ar': 'قوة الإشارة (قدرة الإرسال)'},
    'wifiSaved': {
      'en': 'Wi-Fi settings saved. Devices may need to reconnect.',
      'ar': 'تم حفظ إعدادات الواي فاي. قد تحتاج الأجهزة لإعادة الاتصال.',
    },
    'dns': {'en': 'DNS', 'ar': 'خوادم DNS'},
    'dnsHint': {
      'en': 'Family DNS blocks adult & malicious sites for every device.',
      'ar': 'DNS العائلي يحجب المواقع الضارة وغير اللائقة لكل الأجهزة.',
    },
    'dns_ispDefault': {'en': 'ISP default', 'ar': 'الافتراضي من الشركة'},
    'dns_cloudflare': {'en': 'Cloudflare 1.1.1.1', 'ar': 'Cloudflare 1.1.1.1'},
    'dns_cloudflareFamily': {'en': 'Cloudflare Family', 'ar': 'Cloudflare للعائلة'},
    'dns_adguardFamily': {'en': 'AdGuard Family', 'ar': 'AdGuard للعائلة'},
    'dns_google': {'en': 'Google 8.8.8.8', 'ar': 'Google 8.8.8.8'},
    'dns_custom': {'en': 'Custom', 'ar': 'مخصص'},
    'primaryDns': {'en': 'Primary DNS', 'ar': 'DNS الأساسي'},
    'secondaryDns': {'en': 'Secondary DNS', 'ar': 'DNS الثانوي'},
    'dnsSaved': {'en': 'DNS updated', 'ar': 'تم تحديث DNS'},

    // Devices
    'devicesTitle': {'en': 'Connected devices', 'ar': 'الأجهزة المتصلة'},
    'noDevices': {'en': 'No devices found', 'ar': 'لا توجد أجهزة'},
    'band_band24': {'en': '2.4 GHz', 'ar': '\u20662.4 GHz\u2069'},
    'band_band5': {'en': '5 GHz', 'ar': '\u20665 GHz\u2069'},
    'band_ethernet': {'en': 'Ethernet', 'ar': 'كابل'},
    'band_unknown': {'en': 'Unknown', 'ar': 'غير معروف'},
    'inactive': {'en': 'Offline', 'ar': 'غير نشط'},
    'online': {'en': 'online', 'ar': 'متصل'},

    // Admin webview
    'adminWebOnly': {
      'en': 'In-app WebView is unavailable on web preview. Open in a new browser tab instead?',
      'ar': 'المتصفح الداخلي غير متاح في معاينة الويب. فتح الصفحة في تبويب جديد؟',
    },
    'adminDemo': {
      'en': 'Demo mode: there is no real router admin page. Turn off demo mode to open 192.168.1.1.',
      'ar': 'وضع التجربة: لا توجد صفحة إدارة حقيقية. أوقف وضع التجربة لفتح 192.168.1.1.',
    },
    'openInBrowser': {'en': 'Open in browser', 'ar': 'فتح في المتصفح'},


    // Diagnostics
    'diagTitle': {'en': 'Connection test', 'ar': 'اختبار الاتصال'},
    'diagButton': {'en': 'Test connection', 'ar': 'اختبار الاتصال بالراوتر'},
    'diag_network': {'en': 'Phone on home Wi-Fi', 'ar': 'الموبايل على واي فاي البيت'},
    'diag_reach': {'en': 'Reach router', 'ar': 'الوصول إلى الراوتر'},
    'diag_login': {'en': 'Log in', 'ar': 'تسجيل الدخول'},
    'diag_status': {'en': 'Router status', 'ar': 'حالة الراوتر'},
    'diag_traffic': {'en': 'Traffic counters (usage)', 'ar': 'عدادات الاستهلاك'},
    'diag_devices': {'en': 'Connected devices', 'ar': 'الأجهزة المتصلة'},
    'diag_wifi': {'en': 'Wi-Fi settings', 'ar': 'إعدادات الواي فاي'},
    'diag_dns': {'en': 'DNS', 'ar': 'خوادم DNS'},
    'diag_speed': {'en': 'Speed limit (QoS)', 'ar': 'تحديد السرعة (QoS)'},
    'diagAllOk': {'en': 'Everything works with your router.', 'ar': 'كل شيء يعمل مع الراوتر الخاص بك.'},
    'diagSomeFailed': {
      'en': 'Some steps failed. Tap "Copy report" and send it to the developer so the endpoints can be adjusted for your firmware.',
      'ar': 'بعض الخطوات فشلت. اضغط "نسخ التقرير" وأرسله للمطوّر لضبط التطبيق على إصدار الراوتر عندك.',
    },
    'diagDemoWarning': {
      'en': 'Demo mode is ON — this tests the simulated router, not yours. Turn demo mode off on the setup screen.',
      'ar': 'وضع التجربة مفعّل — هذا يختبر راوتر افتراضي وليس الراوتر الخاص بك. أوقف وضع التجربة من شاشة الإعداد.',
    },
    'diagRunAgain': {'en': 'Run again', 'ar': 'إعادة الاختبار'},
    'diagCopy': {'en': 'Copy report', 'ar': 'نسخ التقرير'},
    'diagCopied': {'en': 'Report copied', 'ar': 'تم نسخ التقرير'},
    'diagDetails': {'en': 'Technical details', 'ar': 'تفاصيل تقنية'},


    // Device usage & blocking
    'blockedCount': {'en': 'blocked', 'ar': 'مقطوع'},
    'topUsers': {'en': 'Top users this cycle', 'ar': 'الأكثر استهلاكاً في هذه الدورة'},
    'thisCycleShort': {'en': 'this cycle', 'ar': 'هذه الدورة'},
    'thisCycle': {'en': 'Used this cycle', 'ar': 'استهلاك هذه الدورة'},
    'ofQuota': {'en': 'of quota', 'ar': 'من الباقة'},
    'ofQuotaLong': {'en': 'Share of the monthly quota', 'ar': 'نسبته من الباقة الشهرية'},
    'shareOfDevices': {'en': 'Share of all devices', 'ar': 'نسبته من استهلاك كل الأجهزة'},
    'today': {'en': 'Today', 'ar': 'اليوم'},
    'connection': {'en': 'Connection', 'ar': 'نوع الاتصال'},
    'signal': {'en': 'Signal', 'ar': 'قوة الإشارة'},
    'blocked': {'en': 'Internet cut', 'ar': 'النت مقطوع'},
    'internetAccess': {'en': 'Internet access', 'ar': 'الوصول للإنترنت'},
    'blockTitle': {'en': 'Cut internet?', 'ar': 'قطع الإنترنت؟'},
    'blockConfirm': {
      'en': 'This device will stay on the Wi-Fi but lose internet access until you turn it back on.',
      'ar': 'سيبقى الجهاز متصلاً بالواي فاي لكن بدون إنترنت حتى تعيد تشغيله من هنا.',
    },
    'blockAction': {'en': 'Cut internet', 'ar': 'اقطع الإنترنت'},
    'unblockAction': {'en': 'Restore internet', 'ar': 'أرجِع الإنترنت'},
    'blockedDone': {'en': 'Internet cut for this device', 'ar': 'تم قطع الإنترنت عن الجهاز'},
    'unblockedDone': {'en': 'Internet restored', 'ar': 'تم إرجاع الإنترنت للجهاز'},
    'renameDevice': {'en': 'Rename device', 'ar': 'تسمية الجهاز'},
    'deviceUsageNote': {
      'en': 'Per-device usage is counted by this app from the router\'s per-device counters while the app or its background sync runs. Traffic between devices at home (e.g. casting) is included, so the total can differ slightly from the ISP figure.',
      'ar': 'استهلاك كل جهاز يحسبه التطبيق من عدادات الراوتر لكل جهاز أثناء تشغيل التطبيق أو المزامنة في الخلفية. يشمل ذلك النقل بين أجهزة البيت (مثل الكاست)، لذلك قد يختلف المجموع قليلاً عن رقم الشركة.',
    },

    // Router counter
    'routerCounter': {'en': 'Router counter (since restart)', 'ar': 'عداد الراوتر (منذ آخر تشغيل)'},
    'sinceBoot': {'en': 'Router running since', 'ar': 'الراوتر شغّال منذ'},
    'routerCounterApplied': {
      'en': 'Usage was corrected automatically from the router counter (it also counts time when the app was closed).',
      'ar': 'تم تصحيح الاستهلاك تلقائياً من عداد الراوتر (يشمل الوقت الذي كان التطبيق فيه مقفولاً).',
    },
    'routerCounterMatches': {
      'en': 'The app\'s count already covers the router counter. Used automatically if it ever gets ahead.',
      'ar': 'حساب التطبيق يغطي عداد الراوتر. سيُستخدم العداد تلقائياً لو زاد عن حساب التطبيق.',
    },
    'routerCounterOldBoot': {
      'en': 'The router was restarted before this cycle began, so its counter includes last cycle — the app\'s own count is used. Use "Calibrate" for the ISP figure.',
      'ar': 'الراوتر اشتغل قبل بداية الدورة الحالية فعدّاده يشمل الدورة السابقة، لذلك يُستخدم حساب التطبيق. استخدم "معايرة" لإدخال رقم الشركة.',
    },

    'unnamedDevice': {'en': 'Unnamed', 'ar': 'جهاز بدون اسم'},
    'thisPhone': {'en': 'This phone', 'ar': 'هذا الموبايل'},
    'blockSelfWarning': {
      'en': 'This is the phone you are using! It will lose internet, but this app keeps working on the home Wi-Fi so you can restore it from here.',
      'ar': 'هذا هو الموبايل الذي تستخدمه الآن! سيُقطع عنه الإنترنت، لكن التطبيق سيظل يعمل على واي فاي البيت لتقدر ترجّعه من هنا.',
    },

    // Misc
    'language': {'en': 'العربية', 'ar': 'English'},
  };

  static String of(Locale locale, String key) {
    final entry = _t[key];
    if (entry == null) return key;
    return entry[locale.languageCode] ?? entry['en'] ?? key;
  }
}

extension AppStringsX on BuildContext {
  String tr(String key) => AppStrings.of(Localizations.localeOf(this), key);
  bool get isArabic => Localizations.localeOf(this).languageCode == 'ar';
}
