import 'package:flutter/material.dart';

/// Farben im Stil von Spotify: fast schwarzer Hintergrund, grüner Akzent.
class AppColors {
  static const accent = Color(0xFF1ED760);
  static const accentDark = Color(0xFF1DB954);
  static const background = Color(0xFF121212);
  static const surface = Color(0xFF181818);
  static const surfaceHigh = Color(0xFF242424);
  static const surfaceHighest = Color(0xFF2A2A2A);
  static const textPrimary = Colors.white;
  static const textSecondary = Color(0xFFB3B3B3);
  static const textMuted = Color(0xFF7A7A7A);
  static const liked = Color(0xFF4B2BD6);
  static const danger = Color(0xFFF15E6C);
}

/// Wandelt "#3a6ea5" (vom Server) in eine Farbe um.
Color? parseHexColor(String? hex) {
  if (hex == null || hex.length != 7 || !hex.startsWith('#')) return null;
  final value = int.tryParse(hex.substring(1), radix: 16);
  return value == null ? null : Color(0xFF000000 | value);
}

/// Dunklere Variante für Farbverläufe hinter Covern.
Color darken(Color color, [double amount = 0.35]) {
  final hsl = HSLColor.fromColor(color);
  return hsl.withLightness((hsl.lightness - amount).clamp(0.08, 1.0)).toColor();
}

ThemeData buildTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: AppColors.accent,
    brightness: Brightness.dark,
  ).copyWith(
    primary: AppColors.accent,
    onPrimary: Colors.black,
    secondary: AppColors.accent,
    surface: AppColors.background,
    onSurface: AppColors.textPrimary,
    error: AppColors.danger,
  );
  final base = ThemeData(useMaterial3: true, colorScheme: scheme, brightness: Brightness.dark);
  return base.copyWith(
    scaffoldBackgroundColor: AppColors.background,
    canvasColor: AppColors.background,
    appBarTheme: const AppBarTheme(
      backgroundColor: AppColors.background,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: Colors.white),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: const Color(0xF2000000),
      indicatorColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      height: 62,
      labelTextStyle: WidgetStateProperty.resolveWith(
        (states) => TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: states.contains(WidgetState.selected) ? Colors.white : AppColors.textSecondary,
        ),
      ),
      iconTheme: WidgetStateProperty.resolveWith(
        (states) => IconThemeData(
          size: 26,
          color: states.contains(WidgetState.selected) ? Colors.white : AppColors.textSecondary,
        ),
      ),
    ),
    listTileTheme: const ListTileThemeData(
      iconColor: AppColors.textSecondary,
      textColor: AppColors.textPrimary,
      contentPadding: EdgeInsets.symmetric(horizontal: 16),
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: AppColors.surfaceHigh,
      surfaceTintColor: Colors.transparent,
      showDragHandle: true,
    ),
    dialogTheme: const DialogThemeData(backgroundColor: AppColors.surfaceHigh, surfaceTintColor: Colors.transparent),
    snackBarTheme: const SnackBarThemeData(
      backgroundColor: Colors.white,
      contentTextStyle: TextStyle(color: Colors.black, fontWeight: FontWeight.w600),
      behavior: SnackBarBehavior.floating,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: AppColors.surfaceHigh,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide.none),
      hintStyle: const TextStyle(color: AppColors.textMuted),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: AppColors.accent,
        foregroundColor: Colors.black,
        textStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
        shape: const StadiumBorder(),
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: Colors.white,
        side: const BorderSide(color: AppColors.textMuted),
        shape: const StadiumBorder(),
      ),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: AppColors.surfaceHigh,
      selectedColor: AppColors.accent,
      labelStyle: const TextStyle(color: Colors.white, fontWeight: FontWeight.w500),
      secondaryLabelStyle: const TextStyle(color: Colors.black, fontWeight: FontWeight.w600),
      side: BorderSide.none,
      shape: const StadiumBorder(),
      showCheckmark: false,
    ),
    sliderTheme: const SliderThemeData(
      activeTrackColor: Colors.white,
      inactiveTrackColor: Color(0x4DFFFFFF),
      thumbColor: Colors.white,
      overlayShape: RoundSliderOverlayShape(overlayRadius: 12),
      thumbShape: RoundSliderThumbShape(enabledThumbRadius: 6),
      trackHeight: 3,
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(color: AppColors.accent),
    dividerTheme: const DividerThemeData(color: AppColors.surfaceHighest, thickness: 1),
  );
}

/// Einheitliche Textstile.
class AppText {
  static const pageTitle = TextStyle(fontSize: 26, fontWeight: FontWeight.w800, color: Colors.white);
  static const sectionTitle = TextStyle(fontSize: 21, fontWeight: FontWeight.w700, color: Colors.white);
  static const tileTitle = TextStyle(fontSize: 15, fontWeight: FontWeight.w500, color: Colors.white);
  static const tileSubtitle = TextStyle(fontSize: 13, color: AppColors.textSecondary);
  static const caption = TextStyle(fontSize: 12, color: AppColors.textSecondary);
}
