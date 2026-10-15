import 'package:flutter/material.dart';

/// Design tokens ported from D:\STARDOM\STAR-DOM-Web\css\site.css.
/// Source of truth: docs/design-system.md.
class AppColors {
  AppColors._();

  // brand
  static const primary = Color(0xFFB70011);
  static const primaryHi = Color(0xFFDC2626);
  static const onPrimary = Color(0xFFFFFFFF);
  static const yellow = Color(0xFFFED01B);
  static const yellowSoft = Color(0xFFFFF3B8);
  static const onYellow = Color(0xFF6F5900);
  static const lineYellow = Color(0xFFEEC200);

  // surfaces
  static const surface = Color(0xFFFFF8F5);
  static const surfaceLow = Color(0xFFFAF2EE);
  static const surfaceMid = Color(0xFFF4ECE8);
  static const surfaceHi = Color(0xFFEEE7E3);
  static const surfaceHighest = Color(0xFFE9E1DD);
  static const card = Color(0xFFFFFFFF);

  // ink
  static const ink = Color(0xFF1E1B19);
  static const inkSoft = Color(0xFF5C403C);
  static const inkFaint = Color(0xFF8A6A62);

  // lines
  static const line = Color(0xFFE6BDB8);
  static const lineHi = Color(0xFFD6D3D1);

  // accents
  static const green = Color(0xFF15803D);
  static const tertiary = Color(0xFF954000);
  static const tertiaryFull = Color(0xFFBC5200);
  static const tertiaryFixed = Color(0xFFFFDBCA);
  static const onTertiaryFixed = Color(0xFF341100);
  static const outline = Color(0xFF916F6B);

  // POS status (derived from source palette)
  static const pendingBg = yellowSoft;
  static const pendingBorder = lineYellow;
  static const pendingText = onYellow;
  static const failedBg = Color(0xFFFFE0DE);
  static const failedBorder = Color(0xFFFFB4AB);
  static const failedText = Color(0xFF93000A);
  static const voidedBg = surfaceHighest;
  static const voidedText = inkSoft;
  static const syncedBg = Color(0xFFE5F6E7);
  static const syncedBorder = Color(0xFFBBF7D0);
  static const syncedText = Color(0xFF14532D);
  static const infoBg = Color(0xFFE5F2FF);
  static const infoText = Color(0xFF1E3A8A);
  static const infoBorder = Color(0xFFBFDBFE);
  static const kpiIconBg = Color(0xFFFFE0DE);
}

class AppRadius {
  AppRadius._();
  static const s = 8.0;
  static const m = 11.0;
  static const l = 14.0;
  static const xl = 18.0;
  static const pill = 999.0;
}

class AppSpacing {
  AppSpacing._();
  static const xs = 4.0;
  static const sm = 8.0;
  static const md = 12.0;
  static const lg = 16.0;
  static const xl = 20.0;
  static const xxl = 24.0;
  static const screen = 16.0;
  static const bottomNav = 64.0;
  static const tapTarget = 48.0;
}

class AppShadows {
  AppShadows._();
  static const sh1 = [
    BoxShadow(color: Color(0x0D3C1410), blurRadius: 2, offset: Offset(0, 1)),
    BoxShadow(color: Color(0x083C1410), blurRadius: 1, offset: Offset(0, 1)),
  ];
  static const sh2 = [
    BoxShadow(color: Color(0x0F3C1410), blurRadius: 6, offset: Offset(0, 2)),
    BoxShadow(color: Color(0x0F3C1410), blurRadius: 20, offset: Offset(0, 8)),
  ];
  static const sh3 = [
    BoxShadow(color: Color(0x1F3C1410), blurRadius: 24, offset: Offset(0, 8)),
    BoxShadow(color: Color(0x0F3C1410), blurRadius: 6, offset: Offset(0, 2)),
  ];
  static const stamp = BoxShadow(
    color: AppColors.ink, blurRadius: 0, offset: Offset(2, 2));
  static const focusRing = [
    BoxShadow(color: Color(0xFFFFFFFF), blurRadius: 0, spreadRadius: 2),
    BoxShadow(color: AppColors.yellow, blurRadius: 0, spreadRadius: 4),
    BoxShadow(color: Color(0x59FED01B), blurRadius: 0, spreadRadius: 6),
  ];
}
