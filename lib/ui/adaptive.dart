import 'package:flutter/material.dart';

/// Adaptive-layout breakpoints for the STAR:DOM POS, tuned for the target
/// device — an iPad (9th gen, 10.2", 1620×2160 px → 810×1080 logical points).
///
/// The app must look right in BOTH orientations on ANY device, but it is
/// *enhanced* for that 10.2" canvas. The numbers below are logical points
/// (Flutter's device-independent pixels), so they hold across every pixel
/// density without recomputation.
///
/// Portrait iPad (narrow) = 810 pt wide. Landscape iPad (wide) = 1080 pt wide.
/// A phone is ~360–430 pt. The `wide` gate therefore means "an iPad held
/// landscape (or a split-view / desktop window)", and everything inside it is
/// an enhancement — never a requirement — so a phone keeps the single-column
/// flow untouched.
class Adaptive {
  Adaptive._();

  /// Below this the app stays a single phone column (two-pane would starve
  /// both halves). ~ a phone in either orientation.
  static const double compact = 600;

  /// At or above this the canvas is wide enough for a real two-pane split —
  /// an iPad landscape (1080 pt) comfortably clears it, portrait (810) does not.
  static const double wide = 900;

  /// The single source of truth for "show the two-pane master/detail split".
  /// True only when the canvas is genuinely wide (iPad landscape), false for
  /// portrait iPad and every phone, so the split never appears where it would
  /// squeeze either pane.
  static bool isWide(BuildContext context) =>
      MediaQuery.sizeOf(context).width >= wide;

  /// True for the **medium** tier — portrait iPad, Android tablet, or a
  /// phone held landscape on a large screen. Gets a compact left rail
  /// (icon + label, 72 px) instead of the bottom bar, but keeps the
  /// single-column content flow.
  static bool isMedium(BuildContext context) {
    final w = MediaQuery.sizeOf(context).width;
    return w >= compact && w < wide;
  }

  static bool isTablet(BuildContext context) => isMedium(context);

  static bool isCompact(BuildContext context) =>
      MediaQuery.sizeOf(context).width < compact;

  static bool isLandscape(BuildContext context) =>
      MediaQuery.orientationOf(context) == Orientation.landscape;

  /// Max width for a single-column form or a centred reading surface (a
  /// receipt, the sign-in card, Settings). Without a cap, a 1080 pt landscape
  /// iPad stretches every field the full width of the screen and the form
  /// stops being readable — inputs run together and the eye loses the row it
  /// is on. Capped and centred, the same form reads comfortably in both
  /// orientations and on a phone, where the cap simply never binds.
  static const double formMax = 560;

  /// Slightly wider cap for KPI/summary surfaces (Reports) that want a little
  /// more breathing room than a bare form but still must not stretch edge to
  /// edge on the landscape canvas.
  static const double wideContentMax = 760;
}

/// Centres [child] and caps it at [maxWidth] so long forms and receipts never
/// stretch across the full landscape iPad canvas. On a phone the cap does not
/// bind and the child fills the width exactly as before.
///
/// Use [Adaptive.formMax] for forms and [Adaptive.wideContentMax] for summary
/// surfaces.
class CenteredWidth extends StatelessWidget {
  const CenteredWidth({
    super.key,
    required this.child,
    this.maxWidth = Adaptive.formMax,
  });

  final Widget child;
  final double maxWidth;

  @override
  Widget build(BuildContext context) => Center(
    child: ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth),
      child: child,
    ),
  );
}
