import 'package:flutter/material.dart';

import 'tokens.dart';

/// App theme built from the ported STAR:DOM design tokens.
class AppTheme {
  AppTheme._();

  /// FONT FALLBACKS (device rule, verified — not assumed).
  ///
  /// `Sora.ttf` as bundled is a Latin-1 subset with 378 mapped code points and
  /// **no ₱ (U+20B1)**; `PlusJakartaSans.ttf` does carry it. Every peso figure
  /// in the app (prices, KPI tiles, line totals) is drawn with a Sora style, so
  /// each Sora style declares PlusJakartaSans as its fallback and the sign
  /// renders instead of a blank box.
  ///
  /// `node scripts/font-check.js assets/fonts/*.ttf` prints both facts and
  /// exits non-zero if it ever stops being true, so a font swap cannot quietly
  /// break the currency symbol again.
  static const soraFallback = ['PlusJakartaSans'];
  static const jakartaFallback = ['Sora'];

  static TextStyle _sora(
    double size,
    FontWeight weight, {
    double height = 1.3,
    double spacing = 0,
  }) => TextStyle(
    fontFamily: 'Sora',
    fontFamilyFallback: soraFallback,
    fontWeight: weight,
    fontSize: size,
    height: height,
    letterSpacing: spacing,
  );

  static TextStyle _jakarta(double size, {double height = 1.6}) => TextStyle(
    fontFamily: 'PlusJakartaSans',
    fontFamilyFallback: jakartaFallback,
    fontWeight: FontWeight.w400,
    fontSize: size,
    height: height,
  );

  static ThemeData light() {
    final scheme = ColorScheme.light(
      primary: AppColors.primary,
      onPrimary: AppColors.onPrimary,
      primaryContainer: AppColors.primaryHi,
      onPrimaryContainer: AppColors.onPrimary,
      secondary: AppColors.yellow,
      onSecondary: AppColors.onYellow,
      secondaryContainer: AppColors.yellowSoft,
      onSecondaryContainer: AppColors.onYellow,
      surface: AppColors.surface,
      onSurface: AppColors.ink,
      onSurfaceVariant: AppColors.inkSoft,
      outline: AppColors.line,
      outlineVariant: AppColors.lineHi,
      error: AppColors.primary,
      onError: AppColors.onPrimary,
      errorContainer: AppColors.failedBg,
      onErrorContainer: AppColors.failedText,
      surfaceContainerLowest: AppColors.card,
      surfaceContainerLow: AppColors.surfaceLow,
      surfaceContainer: AppColors.surfaceMid,
      surfaceContainerHigh: AppColors.surfaceHi,
      surfaceContainerHighest: AppColors.surfaceHighest,
    );

    final text = TextTheme(
      displayLarge: _sora(34, FontWeight.w800, height: 1.1, spacing: -0.5),
      displayMedium: _sora(24, FontWeight.w800, height: 1.15, spacing: -0.4),
      displaySmall: _sora(20, FontWeight.w800, height: 1.2, spacing: -0.3),
      headlineMedium: _sora(18, FontWeight.w700, height: 1.25, spacing: -0.2),
      titleLarge: _sora(15, FontWeight.w700, spacing: -0.1),
      titleMedium: _sora(14.5, FontWeight.w700, height: 1.35, spacing: -0.1),
      bodyLarge: _jakarta(14, height: 1.6),
      bodyMedium: _jakarta(13, height: 1.6),
      bodySmall: _jakarta(12, height: 1.55),
      labelLarge: _sora(13, FontWeight.w700),
      labelMedium: _sora(12, FontWeight.w700),
      labelSmall: _sora(10, FontWeight.w800, height: 1.4, spacing: 1.2),
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: AppColors.surface,
      // Offline rule: an un-themed style must not fall through to the engine's
      // default family. Flutter web can fetch a missing Google font from
      // fonts.gstatic.com, which is impossible at the booth; every style here
      // resolves to a bundled asset instead.
      fontFamily: 'PlusJakartaSans',
      textTheme: text,
      splashFactory: InkSparkle.splashFactory,
      visualDensity: VisualDensity.standard,
      extensions: const [PosTokens()],
      appBarTheme: const AppBarTheme(
        backgroundColor: AppColors.card,
        foregroundColor: AppColors.ink,
        elevation: 0,
        centerTitle: false,
      ),
      dividerTheme: const DividerThemeData(
        color: AppColors.line,
        thickness: 1,
        space: 1,
      ),
    );
  }
}

/// Custom tokens that don't fit ColorScheme/TextTheme.
@immutable
class PosTokens extends ThemeExtension<PosTokens> {
  const PosTokens();

  @override
  PosTokens copyWith() => const PosTokens();

  @override
  PosTokens lerp(ThemeExtension<PosTokens>? other, double t) =>
      const PosTokens();
}
