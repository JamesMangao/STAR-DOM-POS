import 'package:flutter/material.dart';

import 'tokens.dart';

/// App theme built from the ported STAR:DOM design tokens.
class AppTheme {
  AppTheme._();

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

    final text = const TextTheme(
      displayLarge: TextStyle(
          fontFamily: 'Sora', fontWeight: FontWeight.w800, fontSize: 34, height: 1.1, letterSpacing: -0.5),
      displayMedium: TextStyle(
          fontFamily: 'Sora', fontWeight: FontWeight.w800, fontSize: 24, height: 1.15, letterSpacing: -0.4),
      displaySmall: TextStyle(
          fontFamily: 'Sora', fontWeight: FontWeight.w800, fontSize: 20, height: 1.2, letterSpacing: -0.3),
      headlineMedium: TextStyle(
          fontFamily: 'Sora', fontWeight: FontWeight.w700, fontSize: 18, height: 1.25, letterSpacing: -0.2),
      titleLarge: TextStyle(
          fontFamily: 'Sora', fontWeight: FontWeight.w700, fontSize: 15, height: 1.3, letterSpacing: -0.1),
      titleMedium: TextStyle(
          fontFamily: 'Sora', fontWeight: FontWeight.w700, fontSize: 14.5, height: 1.35, letterSpacing: -0.1),
      bodyLarge: TextStyle(fontFamily: 'PlusJakartaSans', fontWeight: FontWeight.w400, fontSize: 14, height: 1.6),
      bodyMedium: TextStyle(fontFamily: 'PlusJakartaSans', fontWeight: FontWeight.w400, fontSize: 13, height: 1.6),
      bodySmall: TextStyle(fontFamily: 'PlusJakartaSans', fontWeight: FontWeight.w400, fontSize: 12, height: 1.55),
      labelLarge: TextStyle(fontFamily: 'Sora', fontWeight: FontWeight.w700, fontSize: 13, height: 1.3),
      labelMedium: TextStyle(fontFamily: 'Sora', fontWeight: FontWeight.w700, fontSize: 12, height: 1.3),
      labelSmall: TextStyle(
          fontFamily: 'Sora', fontWeight: FontWeight.w800, fontSize: 10, height: 1.4, letterSpacing: 1.2),
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: AppColors.surface,
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
      dividerTheme: const DividerThemeData(color: AppColors.line, thickness: 1, space: 1),
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
  PosTokens lerp(ThemeExtension<PosTokens>? other, double t) => const PosTokens();
}
