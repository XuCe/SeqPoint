import 'package:flutter/material.dart';

import 'seq_tokens.dart';

/// 浅色主题：暖纸白底，琥珀作重点。
ThemeData seqLightTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: SeqTokens.accent,
    brightness: Brightness.light,
  ).copyWith(
    primary: SeqTokens.accentInk,
    surface: SeqTokens.paper,
    onSurface: SeqTokens.ink,
    outlineVariant: SeqTokens.line,
    error: SeqTokens.dangerInk,
  );
  return _base(scheme, SeqTokens.paper, SeqTokens.ink, SeqTokens.inkMuted);
}

/// 深色主题：暖黑底，不做简单反相。
ThemeData seqDarkTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: SeqTokens.darkAccent,
    brightness: Brightness.dark,
  ).copyWith(
    primary: SeqTokens.darkAccent,
    surface: SeqTokens.darkBg,
    onSurface: SeqTokens.darkInk,
    outlineVariant: SeqTokens.darkLine,
  );
  return _base(
      scheme, SeqTokens.darkBg, SeqTokens.darkInk, SeqTokens.darkInkMuted);
}

ThemeData _base(ColorScheme scheme, Color bg, Color ink, Color muted) {
  final text = TextTheme(
    displaySmall: TextStyle(
      fontFamily: SeqFonts.serif.first,
      fontFamilyFallback: SeqFonts.serif,
      fontWeight: FontWeight.w700,
      color: ink,
    ),
    headlineSmall: TextStyle(
      fontFamily: SeqFonts.serif.first,
      fontFamilyFallback: SeqFonts.serif,
      fontWeight: FontWeight.w700,
      color: ink,
    ),
    titleMedium: TextStyle(fontWeight: FontWeight.w500, color: ink),
    bodyMedium: TextStyle(color: ink, height: 1.5),
    bodySmall: TextStyle(color: muted, height: 1.4),
    labelSmall: TextStyle(color: muted, letterSpacing: 0.6),
  );

  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: bg,
    fontFamily: SeqFonts.sans.first,
    fontFamilyFallback: SeqFonts.sans,
    textTheme: text,
    dividerTheme: DividerThemeData(color: scheme.outlineVariant, thickness: 1),
    appBarTheme: AppBarTheme(
      backgroundColor: bg,
      foregroundColor: ink,
      elevation: 0,
      centerTitle: false,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(0, SeqSpace.minTapTarget),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(SeqSpace.radiusControl),
        ),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(0, SeqSpace.minTapTarget),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(SeqSpace.radiusControl),
        ),
      ),
    ),
  );
}
