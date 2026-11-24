import 'package:material_ui/material_ui.dart';

class AppColors {
  static const seed = Color(0xFF00BFA6);
  static const download = Color(0xFF3DDC97);
  static const upload = Color(0xFF4EA8FF);
  static const warning = Color(0xFFFFB547);
  static const danger = Color(0xFFFF5C6C);
  static const darkBg = Color(0xFF0E1116);
  static const darkSurface = Color(0xFF161B22);
}

class AppTheme {
  static ThemeData dark() {
    final scheme = ColorScheme.fromSeed(
      seedColor: AppColors.seed,
      brightness: Brightness.dark,
    ).copyWith(surface: AppColors.darkSurface);
    return _base(scheme).copyWith(scaffoldBackgroundColor: AppColors.darkBg);
  }

  static ThemeData light() => _base(ColorScheme.fromSeed(seedColor: AppColors.seed));

  static ThemeData _base(ColorScheme scheme) => ThemeData(
        useMaterial3: true,
        colorScheme: scheme,
        cardTheme: CardThemeData(
          elevation: 0,
          color: scheme.surfaceContainerHigh,
          margin: EdgeInsets.zero,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
        ),
        appBarTheme: AppBarTheme(
          backgroundColor: Colors.transparent,
          surfaceTintColor: Colors.transparent,
          centerTitle: false,
          titleTextStyle: TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: scheme.onSurface),
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            minimumSize: const Size(64, 50),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          ),
        ),
        snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
      );
}
