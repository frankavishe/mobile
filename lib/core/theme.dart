import 'package:flutter/material.dart';

/// Chat App palette (same tokens as the web app): deep ink surfaces, a cobalt accent and a
/// warm coral highlight.
abstract final class Palette {
  // Light
  static const bg = Color(0xFFF4F5F9);
  static const surface = Color(0xFFFFFFFF);
  static const surface2 = Color(0xFFEEF0F6);
  static const border = Color(0xFFDDE1EC);
  static const fg = Color(0xFF151A2D);
  static const muted = Color(0xFF5F6782);
  static const accent = Color(0xFF3550D6);
  static const accentSoft = Color(0xFFE4E9FF);
  static const highlight = Color(0xFFF06C4E);
  static const danger = Color(0xFFC63B3B);
  static const success = Color(0xFF1F8A5B);

  // Dark
  static const bgDark = Color(0xFF0D1020);
  static const surfaceDark = Color(0xFF151A2D);
  static const surface2Dark = Color(0xFF1D2340);
  static const borderDark = Color(0xFF2A3152);
  static const fgDark = Color(0xFFE8EAF4);
  static const mutedDark = Color(0xFF9AA1BD);
  static const accentDark = Color(0xFF7088FF);
  static const accentSoftDark = Color(0xFF232C55);
  static const highlightDark = Color(0xFFFF8A6F);
  static const dangerDark = Color(0xFFFF7272);
}

ThemeData buildTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final scheme = ColorScheme(
    brightness: brightness,
    primary: dark ? Palette.accentDark : Palette.accent,
    onPrimary: dark ? Palette.bgDark : Colors.white,
    primaryContainer: dark ? Palette.accentSoftDark : Palette.accentSoft,
    onPrimaryContainer: dark ? Palette.fgDark : Palette.fg,
    secondary: dark ? Palette.highlightDark : Palette.highlight,
    onSecondary: dark ? Palette.bgDark : Colors.white,
    error: dark ? Palette.dangerDark : Palette.danger,
    onError: dark ? Palette.bgDark : Colors.white,
    surface: dark ? Palette.surfaceDark : Palette.surface,
    onSurface: dark ? Palette.fgDark : Palette.fg,
    onSurfaceVariant: dark ? Palette.mutedDark : Palette.muted,
    surfaceContainerHighest: dark ? Palette.surface2Dark : Palette.surface2,
    outline: dark ? Palette.borderDark : Palette.border,
    outlineVariant: dark ? Palette.borderDark : Palette.border,
  );

  final radius = BorderRadius.circular(12);
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: dark ? Palette.bgDark : Palette.bg,
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surface,
      foregroundColor: scheme.onSurface,
      elevation: 0,
      scrolledUnderElevation: 1,
      centerTitle: false,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: scheme.surfaceContainerHighest,
      border: OutlineInputBorder(borderRadius: radius, borderSide: BorderSide.none),
      focusedBorder: OutlineInputBorder(
        borderRadius: radius,
        borderSide: BorderSide(color: scheme.primary, width: 2),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: radius,
        borderSide: BorderSide(color: scheme.error),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size.fromHeight(48),
        shape: RoundedRectangleBorder(borderRadius: radius),
      ),
    ),
    dividerTheme: DividerThemeData(color: scheme.outline, space: 1),
  );
}
