import 'package:flutter/material.dart';

const codexBackground = Color(0xFF181818);
const codexSurface = Color(0xFF1E1E1E);
const codexRaised = Color(0xFF292929);
const codexBorder = Color(0xFF3B3B3B);
const codexText = Color(0xFFF0F0F0);
const codexMuted = Color(0xFFA6A6A6);
const codexAmber = Color(0xFFD6A84B);
const codexGreen = Color(0xFF58C88C);
const codexBlue = Color(0xFF54A6F8);
// Keep selected white text and blue Markdown links distinct from the fill.
const codexSelection = Color(0xFF525252);
const codexRed = Color(0xFFF07178);

ThemeData buildCodexTheme() {
  final scheme = const ColorScheme.dark(
    primary: codexAmber,
    onPrimary: Color(0xFF241B08),
    secondary: codexBlue,
    onSecondary: Color(0xFF071A2B),
    error: codexRed,
    onError: Color(0xFF2B070A),
    surface: codexSurface,
    onSurface: codexText,
    onSurfaceVariant: codexMuted,
    outline: codexBorder,
  );
  const textTheme = TextTheme(
    headlineSmall: TextStyle(
      color: codexText,
      fontSize: 22,
      fontWeight: FontWeight.w600,
      letterSpacing: 0,
    ),
    titleLarge: TextStyle(
      color: codexText,
      fontSize: 20,
      fontWeight: FontWeight.w600,
      letterSpacing: 0,
    ),
    titleMedium: TextStyle(
      color: codexText,
      fontSize: 16,
      fontWeight: FontWeight.w600,
      letterSpacing: 0,
    ),
    titleSmall: TextStyle(
      color: codexText,
      fontSize: 14,
      fontWeight: FontWeight.w600,
      letterSpacing: 0,
    ),
    bodyLarge: TextStyle(color: codexText, fontSize: 16, letterSpacing: 0),
    bodyMedium: TextStyle(color: codexText, fontSize: 14, letterSpacing: 0),
    bodySmall: TextStyle(color: codexMuted, fontSize: 12, letterSpacing: 0),
    labelLarge: TextStyle(
      color: codexText,
      fontSize: 14,
      fontWeight: FontWeight.w600,
      letterSpacing: 0,
    ),
    labelMedium: TextStyle(
      color: codexText,
      fontSize: 12,
      fontWeight: FontWeight.w500,
      letterSpacing: 0,
    ),
  );
  return ThemeData(
    brightness: Brightness.dark,
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: codexBackground,
    canvasColor: codexBackground,
    textTheme: textTheme,
    textSelectionTheme: const TextSelectionThemeData(
      cursorColor: codexAmber,
      selectionColor: codexSelection,
      selectionHandleColor: codexAmber,
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: codexBackground,
      foregroundColor: codexText,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleSpacing: 12,
    ),
    dividerColor: codexBorder,
    dialogTheme: const DialogThemeData(
      backgroundColor: codexRaised,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(8)),
      ),
    ),
    inputDecorationTheme: const InputDecorationTheme(
      filled: true,
      fillColor: codexSurface,
      contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 13),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.all(Radius.circular(6)),
        borderSide: BorderSide(color: codexBorder),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.all(Radius.circular(6)),
        borderSide: BorderSide(color: codexBorder),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.all(Radius.circular(6)),
        borderSide: BorderSide(color: codexBlue, width: 1.4),
      ),
      labelStyle: TextStyle(color: codexMuted, letterSpacing: 0),
      hintStyle: TextStyle(color: codexMuted, letterSpacing: 0),
    ),
    snackBarTheme: const SnackBarThemeData(
      backgroundColor: Color(0xFF303030),
      contentTextStyle: TextStyle(color: codexText, letterSpacing: 0),
      behavior: SnackBarBehavior.floating,
      width: 420,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(6)),
      ),
    ),
    tooltipTheme: const TooltipThemeData(
      decoration: BoxDecoration(
        color: Color(0xFF333333),
        borderRadius: BorderRadius.all(Radius.circular(4)),
      ),
      textStyle: TextStyle(color: codexText, fontSize: 12, letterSpacing: 0),
    ),
  );
}
