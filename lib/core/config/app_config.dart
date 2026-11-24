/// Build-time configuration.
///
/// Demo mode is ON by default so the app renders fully in cloud previews
/// (Flutter Web / emulators that can't reach 192.168.1.1). Build for your
/// real router with:
///   flutter run --dart-define=DEMO_MODE=false
/// or simply switch "Demo mode" off on the setup screen.
class AppConfig {
  static const bool demoModeDefault = bool.fromEnvironment('DEMO_MODE', defaultValue: true);
  static const String defaultGatewayIp = '192.168.1.1';

  /// Poll interval for live rate + usage counters.
  static const Duration demoPollInterval = Duration(seconds: 2);
  static const Duration routerPollInterval = Duration(seconds: 5);

  static const List<double> quotaPresetsGb = [140, 250, 500, 1000];
  static const List<double> speedPresetsMbps = [2, 6, 10, 20];
}
