import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;

import '../core/format.dart';
import '../core/icons.dart';
import '../core/tokens.dart';
import '../core/web_apis.dart' as web;
import '../data/api.dart';
import '../data/auth.dart';
import '../data/catalogue.dart';
import '../data/logic.dart';
import '../data/sync.dart';
import 'scope.dart';
import 'sign_in.dart';

// ---------------------------------------------------------------- typography

/// The ₱ rule, in one place: every Sora style declares PlusJakartaSans as its
/// fallback, because the bundled Sora has no U+20B1. Never build a Sora
/// [TextStyle] anywhere else in the app — `node scripts/font-check.js` proves
/// the glyphs, this is what puts them on screen.
TextStyle sora(
  double size, {
  FontWeight weight = FontWeight.w700,
  Color? color,
  double height = 1.3,
  double letterSpacing = 0,
}) => TextStyle(
  fontFamily: 'Sora',
  fontFamilyFallback: const ['PlusJakartaSans'],
  fontWeight: weight,
  fontSize: size,
  height: height,
  letterSpacing: letterSpacing,
  color: color,
  // Design §1.2: every peso/KPI figure is tabular-nums. Both bundled fonts
  // carry the `tnum` GSUB feature (proven by `scripts/font-check.js`), so a
  // changing total never makes the ₱ column jitter.
  fontFeatures: const [FontFeature.tabularFigures()],
);

/// Body copy (Plus Jakarta Sans, bundled, carries ₱ on its own).
TextStyle jakarta(
  double size, {
  FontWeight weight = FontWeight.w400,
  Color? color,
  double height = 1.5,
}) => TextStyle(
  fontFamily: 'PlusJakartaSans',
  fontWeight: weight,
  fontSize: size,
  height: height,
  color: color,
);

/// Order numbers, reference numbers and SKUs: Cascadia → Consolas → Courier
/// New → the platform generic. System faces only — the offline rule forbids a
/// font that has to be fetched.
TextStyle mono(
  double size, {
  FontWeight weight = FontWeight.w700,
  Color? color,
}) => TextStyle(
  fontFamily: 'Consolas',
  fontFamilyFallback: const ['Courier New', 'monospace'],
  fontWeight: weight,
  fontSize: size,
  height: 1.35,
  color: color,
  // Order numbers and reference numbers line up column-wise (design §1.2).
  fontFeatures: const [FontFeature.tabularFigures()],
);

/// Design §2.10: under reduced motion everything is instant. One predicate,
/// checked by every animation in the app — the OS setting (iOS "Reduce
/// Motion", surfaced by Flutter as `disableAnimations`) OR the browser's
/// live `prefers-reduced-motion` media query (which can change mid-session).
bool posMotion(BuildContext context) =>
    !MediaQuery.disableAnimationsOf(context) && !web.prefersReducedMotion();

/// What drove the last interaction: a hardware key (barcode scanner, external
/// keyboard, switch control) or a finger. Set by the root listener in
/// `main.dart` — pointer-down resets it, any key-down sets it — and read when
/// a widget decides whether to draw its focus-visible ring. A finger never
/// gets a ring; keyboard/Guided-Access traversal always does.
class InputMode {
  InputMode._();

  static bool keyboard = false;
}

/// A peso figure: Sora 800, tabular feel, brand red by default.
Widget priceText(
  double value, {
  double size = 15.5,
  Color color = AppColors.primary,
  TextAlign align = TextAlign.right,
}) => Text(
  Fmt.peso(value),
  textAlign: align,
  style: sora(size, weight: FontWeight.w800, color: color, height: 1.1),
);

// --------------------------------------------------------------------- cards

class PosCard extends StatefulWidget {
  const PosCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(AppSpacing.lg),
    this.margin,
    this.onTap,
    this.onLongPress,
    this.color = AppColors.card,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry? margin;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final Color color;

  @override
  State<PosCard> createState() => _PosCardState();
}

class _PosCardState extends State<PosCard> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final tappable = widget.onTap != null || widget.onLongPress != null;
    // A finger is the only input device (design §Touch): a tappable card must
    // ANSWER the tap — Ink ripple + a 60 ms press scale, same language as
    // PosButton. A bare GestureDetector rendered nothing at all.
    final card = Container(
      margin: widget.margin,
      decoration: BoxDecoration(
        color: widget.color,
        borderRadius: BorderRadius.circular(AppRadius.l),
        border: Border.all(color: AppColors.line),
        boxShadow: AppShadows.sh1,
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(AppRadius.l),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: tappable ? widget.onTap : null,
          onLongPress: widget.onLongPress,
          onTapDown: tappable ? (_) => setState(() => _pressed = true) : null,
          onTapUp: tappable ? (_) => setState(() => _pressed = false) : null,
          onTapCancel: tappable ? () => setState(() => _pressed = false) : null,
          borderRadius: BorderRadius.circular(AppRadius.l),
          child: Padding(padding: widget.padding, child: widget.child),
        ),
      ),
    );
    if (!tappable) return card;
    return AnimatedScale(
      scale: _pressed ? 0.98 : 1.0,
      duration: posMotion(context)
          ? const Duration(milliseconds: 60)
          : Duration.zero,
      curve: Curves.easeOut,
      child: card,
    );
  }
}

/// A titled block: Sora 15 heading above a card, with the design system's
/// `.panel` accent — a 6 px `primary → yellow → tertiary-full` strip clipped
/// to the card's top corners (design §2.3).
class SectionCard extends StatelessWidget {
  const SectionCard({
    super.key,
    required this.title,
    required this.children,
    this.trailing,
  });

  final String title;
  final List<Widget> children;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 2, bottom: AppSpacing.sm),
            child: Row(
              children: [
                Expanded(
                  child: Text(title, style: sora(15, weight: FontWeight.w700)),
                ),
                ?trailing,
              ],
            ),
          ),
          PosCard(
            padding: EdgeInsets.zero,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const _PanelAccent(),
                Padding(
                  padding: const EdgeInsets.all(AppSpacing.lg),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: children,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The 6 px gradient strip that marks a `.panel` (design §2.3).
class _PanelAccent extends StatelessWidget {
  const _PanelAccent();

  @override
  Widget build(BuildContext context) => Container(
    height: 6,
    decoration: const BoxDecoration(
      gradient: LinearGradient(
        colors: [
          AppColors.primary,
          AppColors.yellow,
          AppColors.tertiaryFull,
        ],
      ),
    ),
  );
}

/// label … value row used by Settings/Reports detail lists.
class DetailRow extends StatelessWidget {
  const DetailRow(this.label, this.value, {this.valueStyle, super.key});

  final String label;
  final String value;
  final TextStyle? valueStyle;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 150,
            child: Text(
              label,
              style: sora(
                12,
                weight: FontWeight.w700,
                color: AppColors.inkSoft,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: valueStyle ?? jakarta(13, weight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}

// -------------------------------------------------------------------- badges

enum BadgeKind { pending, synced, failed, voided, info, neutral }

class StatusBadge extends StatelessWidget {
  const StatusBadge(this.label, {this.kind = BadgeKind.neutral, super.key});

  final String label;
  final BadgeKind kind;

  @override
  Widget build(BuildContext context) {
    final (bg, border, fg) = switch (kind) {
      BadgeKind.pending => (
        AppColors.pendingBg,
        AppColors.pendingBorder,
        AppColors.pendingText,
      ),
      BadgeKind.synced => (
        AppColors.syncedBg,
        AppColors.syncedBorder,
        AppColors.syncedText,
      ),
      BadgeKind.failed => (
        AppColors.failedBg,
        AppColors.failedBorder,
        AppColors.failedText,
      ),
      BadgeKind.voided => (
        AppColors.voidedBg,
        AppColors.lineHi,
        AppColors.voidedText,
      ),
      BadgeKind.info => (
        AppColors.infoBg,
        AppColors.infoBorder,
        AppColors.infoText,
      ),
      BadgeKind.neutral => (
        AppColors.surfaceMid,
        AppColors.line,
        AppColors.inkSoft,
      ),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(AppRadius.pill),
        border: Border.all(color: border),
      ),
      child: Text(
        label.toUpperCase(),
        style: sora(10, weight: FontWeight.w800, color: fg, letterSpacing: 0.5),
      ),
    );
  }
}

/// The badge colour of a shelf status.
///
/// "Out of Stock" is a failure (red), "Restock" is information (blue),
/// "Low Stock" is a warning (amber) and "In Stock" is the good news (green).
/// An unknown value stays neutral — shown, never rewritten.
BadgeKind stockBadgeKind(String status) {
  switch (status) {
    case StockStatus.inStock:
      return BadgeKind.synced;
    case StockStatus.lowStock:
      return BadgeKind.pending;
    case StockStatus.restock:
      return BadgeKind.info;
    case StockStatus.outOfStock:
      return BadgeKind.failed;
    default:
      return BadgeKind.neutral;
  }
}

// ------------------------------------------------------------------- buttons

enum PosButtonVariant { primary, secondary, ghost, danger, quiet }

/// The one button. ≥48 pt tall (device rule), radius 10, Sora 700. The primary
/// variant carries the brutalist `--stamp` hard offset, used only where the
/// design allows it: the big CTAs on payment screens, Close Day, Complete Sale.
class PosButton extends StatefulWidget {
  const PosButton({
    super.key,
    required this.label,
    this.onPressed,
    this.icon,
    this.variant = PosButtonVariant.primary,
    this.height = 52,
    this.expanded = true,
    this.busy = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final PosButtonVariant variant;
  final double height;
  final bool expanded;
  final bool busy;

  @override
  State<PosButton> createState() => _PosButtonState();
}

class _PosButtonState extends State<PosButton> {
  bool _pressed = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onPressed != null && !widget.busy;
    // Spec §3 focus-visible: keyboard traversal gets the crimson ring, a
    // finger never does (InputMode, set by the shell's root listener).
    final showRing = _focused && InputMode.keyboard && enabled;
    final (bg, fg, border, shadow) = switch (widget.variant) {
      PosButtonVariant.primary => (
        AppColors.primary,
        AppColors.onPrimary,
        AppColors.primary,
        enabled ? const [AppShadows.stamp] : const <BoxShadow>[],
      ),
      PosButtonVariant.secondary => (
        AppColors.yellow,
        const Color(0xFF231B00),
        AppColors.lineYellow,
        enabled ? AppShadows.sh1 : const <BoxShadow>[],
      ),
      PosButtonVariant.ghost => (
        Colors.transparent,
        AppColors.ink,
        AppColors.lineHi,
        const <BoxShadow>[],
      ),
      PosButtonVariant.danger => (
        AppColors.card,
        AppColors.primary,
        AppColors.primary,
        const <BoxShadow>[],
      ),
      PosButtonVariant.quiet => (
        AppColors.surfaceMid,
        AppColors.ink,
        AppColors.line,
        const <BoxShadow>[],
      ),
    };

    final labelColor = enabled
        ? fg
        : switch (widget.variant) {
            PosButtonVariant.primary ||
            PosButtonVariant.secondary => fg.withValues(alpha: 0.6),
            _ => AppColors.inkFaint,
          };

    final child = Row(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (widget.busy) ...[
          SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2, color: labelColor),
          ),
          const SizedBox(width: 10),
        ] else if (widget.icon != null) ...[
          Icon(widget.icon, size: 20, color: labelColor),
          const SizedBox(width: 8),
        ],
        Flexible(
          child: Text(
            widget.label,
            overflow: TextOverflow.ellipsis,
            style: sora(14, weight: FontWeight.w800, color: labelColor),
          ),
        ),
      ],
    );

    final button = Focus(
      onFocusChange: (f) {
        if (f != _focused) setState(() => _focused = f);
      },
      child: Material(
        color: enabled ? bg : AppColors.surfaceHi,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          onTapDown: enabled ? (_) => setState(() => _pressed = true) : null,
          onTapUp: enabled ? (_) => setState(() => _pressed = false) : null,
          onTapCancel: enabled ? () => setState(() => _pressed = false) : null,
          onTap: enabled ? widget.onPressed : null,
          borderRadius: BorderRadius.circular(10),
          child: AnimatedScale(
            scale: _pressed ? 0.96 : 1.0,
            duration: posMotion(context)
                ? const Duration(milliseconds: 60)
                : Duration.zero,
            curve: Curves.easeOut,
            child: Container(
              height: widget.height,
              padding: const EdgeInsets.symmetric(horizontal: 18),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: enabled ? border : AppColors.lineHi),
                boxShadow: [
                  ...shadow,
                  if (showRing) ...AppShadows.focusVisibleRing,
                ],
              ),
              alignment: Alignment.center,
              child: child,
            ),
          ),
        ),
      ),
    );

    if (!widget.expanded) return button;
    return SizedBox(width: double.infinity, child: button);
  }
}

// -------------------------------------------------------------------- fields

/// Label + input. Every input uses a ≥16 px font so Safari on the iPad does
/// not auto-zoom the page when the on-screen keyboard opens (device rule).
///
/// Pass EITHER a [controller] (the caller owns the text) or a one-shot [value]
/// (the field keeps its own controller and follows [value] across rebuilds).
class PosField extends StatefulWidget {
  const PosField({
    super.key,
    required this.label,
    this.controller,
    this.hint,
    this.value,
    this.onChanged,
    this.onSubmitted,
    this.keyboardType,
    this.obscureText = false,
    this.prefix,
    this.suffix,
    this.readOnly = false,
    this.maxLines = 1,
    this.textInputAction,
    this.required = false,
    this.autofocus = false,
  });

  final String label;
  final TextEditingController? controller;
  final String? hint;
  final String? value;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final TextInputType? keyboardType;
  final bool obscureText;
  final String? prefix;
  final Widget? suffix;
  final bool readOnly;
  final int maxLines;
  final TextInputAction? textInputAction;
  final bool required;
  final bool autofocus;

  @override
  State<PosField> createState() => _PosFieldState();
}

class _PosFieldState extends State<PosField> {
  TextEditingController? _internal;
  bool _focused = false;

  TextEditingController? get _controller => widget.controller ?? _internal;

  @override
  void initState() {
    super.initState();
    if (widget.controller == null && widget.value != null) {
      _internal = TextEditingController(text: widget.value);
    }
  }

  @override
  void didUpdateWidget(PosField old) {
    super.didUpdateWidget(old);
    // Follow a changed `value` only when nobody is typing into it, so a parent
    // rebuild mid-edit cannot yank the caret away.
    if (widget.controller == null &&
        widget.value != null &&
        widget.value != old.value &&
        widget.value != _internal?.text) {
      _internal?.text = widget.value!;
    }
  }

  @override
  void dispose() {
    _internal?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final w = widget;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 2, bottom: 6),
            child: Text.rich(
              TextSpan(
                text: w.label.toUpperCase(),
                style: sora(
                  11,
                  weight: FontWeight.w800,
                  color: AppColors.inkSoft,
                  letterSpacing: 0.6,
                ),
                children: [
                  if (w.required)
                    TextSpan(
                      text: ' *',
                      style: sora(
                        11,
                        weight: FontWeight.w800,
                        color: AppColors.primary,
                      ),
                    ),
                ],
              ),
            ),
          ),
          // Spec §2.2: focus = ink border + the yellow --focus-ring. Text
          // fields show it on ANY focus (typing is visible either way),
          // unlike buttons which only ring on keyboard traversal.
          Focus(
            onFocusChange: (f) {
              if (f != _focused) setState(() => _focused = f);
            },
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                boxShadow: _focused
                    ? AppShadows.focusRing
                    : const <BoxShadow>[],
              ),
              child: TextField(
                controller: _controller,
                onChanged: w.onChanged,
                onSubmitted: w.onSubmitted,
                keyboardType: w.keyboardType,
                obscureText: w.obscureText,
                readOnly: w.readOnly,
                maxLines: w.maxLines,
                autofocus: w.autofocus,
                textInputAction: w.textInputAction,
                style: jakarta(16, weight: FontWeight.w500, height: 1.4),
                decoration: InputDecoration(
                  hintText: w.hint,
                  hintStyle: jakarta(
                    16,
                    weight: FontWeight.w400,
                    color: AppColors.inkFaint,
                  ),
                  prefixText: w.prefix,
                  prefixStyle: jakarta(16, weight: FontWeight.w600),
                  suffix: w.suffix,
                  filled: true,
                  fillColor: AppColors.card,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 14,
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: const BorderSide(color: AppColors.line),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: const BorderSide(color: AppColors.ink, width: 1.5),
                  ),
                  disabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: const BorderSide(color: AppColors.lineHi),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Pill search box (design §2.2): focus-within turns it white with the ink
/// border and the yellow --focus-ring.
class SearchField extends StatefulWidget {
  const SearchField({
    super.key,
    required this.controller,
    this.hint = 'Search products',
    this.onChanged,
    this.onSubmitted,
  });

  final TextEditingController controller;
  final String hint;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;

  @override
  State<SearchField> createState() => _SearchFieldState();
}

class _SearchFieldState extends State<SearchField> {
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    // The clear (×) button must appear the moment there is text, not on the
    // parent's next rebuild.
    widget.controller.addListener(_onControllerChanged);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChanged);
    super.dispose();
  }

  void _onControllerChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      onFocusChange: (f) {
        if (f != _focused) setState(() => _focused = f);
      },
      child: Container(
        height: 46,
        decoration: BoxDecoration(
          color: _focused ? AppColors.card : AppColors.surfaceLow,
          borderRadius: BorderRadius.circular(AppRadius.pill),
          border: Border.all(color: _focused ? AppColors.ink : AppColors.line),
          boxShadow: _focused
              ? AppShadows.focusRing
              : const <BoxShadow>[],
        ),
        alignment: Alignment.center,
        child: TextField(
          controller: widget.controller,
          onChanged: widget.onChanged,
          onSubmitted: widget.onSubmitted,
          textInputAction: TextInputAction.search,
          style: jakarta(16, weight: FontWeight.w500),
          decoration: InputDecoration(
            isDense: true,
            border: InputBorder.none,
            hintText: widget.hint,
            hintStyle: jakarta(16, color: AppColors.inkFaint),
            prefixIcon: const Icon(
              AppIcons.search,
              size: 20,
              color: AppColors.inkFaint,
            ),
            suffixIcon: widget.controller.text.isNotEmpty
                ? IconButton(
                    tooltip: 'Clear',
                    onPressed: widget.controller.clear,
                    icon: const Icon(
                      AppIcons.close,
                      size: 18,
                      color: AppColors.inkSoft,
                    ),
                  )
                : null,
            contentPadding: const EdgeInsets.symmetric(vertical: 12),
          ),
        ),
      ),
    );
  }
}

/// Pill filter chip: white with a warm border, solid crimson when on.
class PillChip extends StatelessWidget {
  const PillChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.dense = false,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? AppColors.primary : AppColors.card,
      borderRadius: BorderRadius.circular(AppRadius.pill),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadius.pill),
        child: Container(
          padding: EdgeInsets.symmetric(
            horizontal: dense ? 12 : 15,
            vertical: dense ? 7 : 9,
          ),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppRadius.pill),
            border: Border.all(
              color: selected ? AppColors.primary : AppColors.line,
            ),
          ),
          child: Text(
            label,
            style: sora(
              13,
              weight: FontWeight.w700,
              color: selected ? AppColors.onPrimary : AppColors.inkSoft,
            ),
          ),
        ),
      ),
    );
  }
}

// ------------------------------------------------------------------ controls

/// 48 pt square −/+ pair with the quantity between them (design: 46 px stepper,
/// raised to the 48 pt minimum the iPad rules require).
class QtyStepper extends StatelessWidget {
  const QtyStepper({
    super.key,
    required this.quantity,
    required this.onIncrement,
    required this.onDecrement,
    this.onTapQuantity,
    this.size = 48,
  });

  final int quantity;
  final VoidCallback onIncrement;
  final VoidCallback onDecrement;
  final VoidCallback? onTapQuantity;
  final double size;

  @override
  Widget build(BuildContext context) {
    Widget key(IconData icon, VoidCallback onTap) => Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(AppRadius.m),
        border: Border.all(color: AppColors.line),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadius.m),
        child: Icon(icon, size: 22, color: AppColors.ink),
      ),
    );

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        key(AppIcons.minus, onDecrement),
        InkWell(
          onTap: onTapQuantity,
          borderRadius: BorderRadius.circular(AppRadius.s),
          child: Tooltip(
            message: 'Tap to type quantity',
            child: Container(
              width: 52,
              height: size,
              alignment: Alignment.center,
              child: Text(
                '$quantity',
                textAlign: TextAlign.center,
                style: sora(19, weight: FontWeight.w800),
              ),
            ),
          ),
        ),
        key(AppIcons.plus, onIncrement),
      ],
    );
  }
}

/// Neutral placeholder for a product with no photo (~4 in 10) and for a QR
/// code that has not been uploaded yet.
class NeutralPlaceholder extends StatelessWidget {
  const NeutralPlaceholder({
    super.key,
    this.icon = AppIcons.products,
    this.radius,
  });

  final IconData icon;
  final double? radius;

  @override
  Widget build(BuildContext context) => Container(
    decoration: BoxDecoration(
      color: AppColors.surfaceMid,
      borderRadius: BorderRadius.circular(radius ?? AppRadius.m),
    ),
    child: Center(child: Icon(icon, size: 30, color: AppColors.inkFaint)),
  );
}

// -------------------------------------------------------------- sync chip

/// Offline / Synced / Failed / Sign in to sync — one component, used by the
/// app bar of the shell AND of every pushed route (the design puts it on all
/// of them), all reading the shell's single status notifier.
class SyncChip extends StatefulWidget {
  const SyncChip({super.key});

  @override
  State<SyncChip> createState() => _SyncChipState();
}

class _SyncChipState extends State<SyncChip> {
  StreamSubscription<bool>? _authSub;
  bool _signedIn = false;

  @override
  void initState() {
    super.initState();
    _signedIn = OwnerAuth.instance.signedIn;
    _authSub = OwnerAuth.instance.changes.listen((v) {
      if (mounted) setState(() => _signedIn = v);
    });
  }

  @override
  void dispose() {
    _authSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scope = PosScope.of(context);
    final status = scope.status;
    return ValueListenableBuilder<SyncSummary>(
      valueListenable: status,
      builder: (context, s, _) {
        final (label, color, bg, border) = _paint(s, _signedIn);
        return Tooltip(
          message: _signedIn
              ? 'Tap to sync with shop server'
              : 'Tap to sign in and sync',
          child: InkWell(
            borderRadius: BorderRadius.circular(AppRadius.pill),
            onTap: () async {
              if (!_signedIn) {
                // Capture navigator before the async gap.
                final nav = Navigator.of(context);
                await nav.push(
                  MaterialPageRoute<void>(builder: (_) => const SignInScreen()),
                );
                // After sign-in screen closes, attempt an immediate sync.
                if (!mounted) return;
                if (OwnerAuth.instance.signedIn) {
                  ScaffoldMessenger.of(this.context).showSnackBar(
                    const SnackBar(
                      content: Text('Signed in — syncing data…'),
                      duration: Duration(milliseconds: 2000),
                    ),
                  );
                  await scope.sync.syncAll();
                }
                return;
              }
              final messenger = ScaffoldMessenger.of(context);
              messenger.showSnackBar(
                const SnackBar(
                  content: Text('Syncing data with server…'),
                  duration: Duration(milliseconds: 1500),
                ),
              );
              await scope.sync.syncAll();
              if (!mounted) return;
              // Read the queue directly: the shared status notifier is
              // refreshed asynchronously and can lag the sync just done —
              // deciding “all synced” vs error on stale data could show
              // the wrong verdict.
              final storeId = scope.storeId;
              final pending = storeId == null
                  ? 0
                  : await scope.db.pendingCount(storeId);
              if (!mounted) return;
              // Green only for an empty queue AND a clean run: a pull that
              // skipped rows must not report "synced" while it didn't.
              if (pending == 0 && scope.sync.lastSyncError == null) {
                messenger.showSnackBar(
                  const SnackBar(
                    content: Text('All data synced with server!'),
                    backgroundColor: Color(0xFF2E7D32),
                    duration: Duration(seconds: 2),
                  ),
                );
              } else {
                // One shared sentence for every incomplete-sync entry point
                // (chip + data-loss banner) — SyncEngine.incompleteMessage.
                messenger.showSnackBar(
                  SnackBar(
                    content: Text(scope.sync.incompleteMessage),
                    backgroundColor: AppColors.primary,
                    duration: const Duration(seconds: 4),
                  ),
                );
              }
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
              decoration: BoxDecoration(
                color: bg,
                borderRadius: BorderRadius.circular(AppRadius.pill),
                border: Border.all(color: border),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 7,
                    height: 7,
                    decoration: BoxDecoration(
                      color: color,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 7),
                  Text(
                    label,
                    style: sora(12, weight: FontWeight.w800, color: color),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  (String, Color, Color, Color) _paint(SyncSummary s, bool signedIn) {
    // Selling works signed out — but the badge must say so, because syncing
    // genuinely needs the owner's session (plan: "Sign in to sync").
    if (!signedIn && Api.instance.isReady) {
      return (
        'Sign in to sync',
        AppColors.onYellow,
        AppColors.yellowSoft,
        AppColors.pendingBorder,
      );
    }
    return switch (s.state) {
      SyncState.synced => (
        'Synced',
        AppColors.syncedText,
        AppColors.syncedBg,
        AppColors.syncedBorder,
      ),
      SyncState.offline => (
        s.pending > 0 ? 'Offline · ${s.pending}' : 'Offline',
        AppColors.onYellow,
        AppColors.yellowSoft,
        AppColors.pendingBorder,
      ),
      SyncState.failed => (
        'Failed · ${s.pending}',
        AppColors.failedText,
        AppColors.failedBg,
        AppColors.failedBorder,
      ),
    };
  }
}

// ------------------------------------------------------------- empty states

class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.message,
    this.action,
  });

  final IconData icon;
  final String title;
  final String? message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                color: AppColors.surfaceHi,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Icon(icon, size: 26, color: AppColors.inkFaint),
            ),
            const SizedBox(height: 14),
            Text(
              title,
              textAlign: TextAlign.center,
              style: sora(15, weight: FontWeight.w700, color: AppColors.ink),
            ),
            if (message != null) ...[
              const SizedBox(height: 6),
              Text(
                message!,
                textAlign: TextAlign.center,
                style: jakarta(13, color: AppColors.inkSoft),
              ),
            ],
            if (action != null) ...[const SizedBox(height: 16), action!],
          ],
        ),
      ),
    );
  }
}

/// Inline alert (design §2.9): err / ok / info.
class PosAlert extends StatelessWidget {
  const PosAlert.err({super.key, required this.text}) : _kind = _AlertKind.err;

  const PosAlert.ok({super.key, required this.text}) : _kind = _AlertKind.ok;

  const PosAlert.info({super.key, required this.text})
    : _kind = _AlertKind.info;

  final _AlertKind _kind;
  final String text;

  @override
  Widget build(BuildContext context) {
    final (bg, fg, border, icon) = switch (_kind) {
      _AlertKind.err => (
        AppColors.failedBg,
        AppColors.failedText,
        AppColors.failedBorder,
        AppIcons.error,
      ),
      _AlertKind.ok => (
        AppColors.syncedBg,
        AppColors.syncedText,
        AppColors.syncedBorder,
        AppIcons.check,
      ),
      _AlertKind.info => (
        AppColors.infoBg,
        AppColors.infoText,
        AppColors.infoBorder,
        AppIcons.info,
      ),
    };
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(AppRadius.m),
        border: Border.all(color: border),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: fg),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              text,
              style: jakarta(13, weight: FontWeight.w600, color: fg),
            ),
          ),
        ],
      ),
    );
  }
}

enum _AlertKind { err, ok, info }

// ------------------------------------------------------------ dialogs/sheets

/// One confirmation for every destructive action (void, delete, discard).
Future<bool> confirm(
  BuildContext context, {
  required String title,
  required String message,
  String confirmLabel = 'Confirm',
  bool danger = false,
}) async {
  final yes = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: AppColors.card,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.xl),
        side: const BorderSide(color: AppColors.lineHi),
      ),
      title: Text(title, style: sora(18, weight: FontWeight.w800)),
      content: Text(message, style: jakarta(14)),
      actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: Text('Cancel', style: sora(13, color: AppColors.inkSoft)),
        ),
        PosButton(
          label: confirmLabel,
          expanded: false,
          height: 44,
          variant: danger ? PosButtonVariant.danger : PosButtonVariant.primary,
          onPressed: () => Navigator.of(ctx).pop(true),
        ),
      ],
    ),
  );
  return yes ?? false;
}

void showSnack(
  BuildContext context,
  String message, {
  bool error = false,
  String? actionLabel,
  VoidCallback? onAction,
  Duration? duration,
}) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        backgroundColor: AppColors.card,
        // A snack with an action (Undo) stays the full 5 s — the default 4 s
        // cuts the window too short for a mid-sale mis-tap.
        duration: duration ??
            (actionLabel == null
                ? const Duration(seconds: 4)
                : const Duration(seconds: 5)),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.l),
          side: BorderSide(
            color: error ? AppColors.failedBorder : AppColors.syncedBorder,
            width: 1.5,
          ),
        ),
        content: Text(
          message,
          style: jakarta(
            13,
            weight: FontWeight.w600,
            color: error ? AppColors.failedText : AppColors.syncedText,
          ),
        ),
        action: actionLabel == null
            ? null
            : SnackBarAction(
                label: actionLabel,
                textColor: error ? AppColors.failedText : AppColors.green,
                onPressed: onAction ?? () {},
              ),
      ),
    );
}

// ------------------------------------------------------------------- images

/// Offline-first image from the `pos-assets` bucket.
///
/// Order: the LOCAL `image_cache` (renders with the network off) → fetch once
/// over the network and cache the bytes (W3) → neutral placeholder. One image
/// is one drift row; bytes are never kept in memory beyond the widget that
/// shows them, and an in-flight set stops a product grid from downloading the
/// same file ten times.
class StorageImage extends StatefulWidget {
  const StorageImage({
    super.key,
    required this.path,
    this.productId,
    this.width,
    this.height,
    this.fit = BoxFit.cover,
    this.icon = AppIcons.products,
    this.radius,
  });

  final String? path;

  /// The product this picture belongs to. When the app carries the artwork in
  /// its bundle (the catalogue), the picture is read from there — no network,
  /// no cache, nothing to wait for.
  final String? productId;
  final double? width;
  final double? height;
  final BoxFit fit;
  final IconData icon;
  final double? radius;

  @override
  State<StorageImage> createState() => _StorageImageState();
}

class _StorageImageState extends State<StorageImage> {
  static final Set<String> _inFlight = <String>{};

  Uint8ListCache? _cached;
  bool _tried = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(StorageImage old) {
    super.didUpdateWidget(old);
    if (old.path != widget.path || old.productId != widget.productId) {
      _cached = null;
      _tried = false;
      _load();
    }
  }

  /// The artwork that ships inside the app, if there is one.
  ///
  /// The catalogue's pictures are named after the product id, so the bundled
  /// file is found from the product — and a path that already points into the
  /// bundle is used as it is.
  String? _bundledAsset() {
    final productId = widget.productId;
    if (productId != null) {
      final asset = Catalogue.current?.assetFor(productId);
      if (asset != null) return asset;
    }
    final path = widget.path;
    if (path != null && path.startsWith('assets/')) return path;
    return null;
  }

  Future<void> _load() async {
    final path = widget.path;
    if ((path == null || path.isEmpty) && widget.productId == null) return;
    if (_tried) return;
    _tried = true;

    // 1. The artwork inside the app bundle: works with no network at all.
    final asset = _bundledAsset();
    if (asset != null) {
      try {
        final data = await rootBundle.load(asset);
        if (!mounted) return;
        setState(
          () => _cached = Uint8ListCache(
            data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
          ),
        );
        return;
      } catch (_) {
        // A missing file is not a crash: fall through to the other sources.
      }
    }

    if (path == null || path.isEmpty) return;

    final scope = PosScope.read(context);
    final cached = await scope.db.cachedImage(path);
    if (!mounted) return;
    if (cached != null) {
      setState(() => _cached = Uint8ListCache(cached.bytes));
      return;
    }

    // Nothing local: only a configured build with a session can reach the
    // private bucket, and a failure is NOT an error — the placeholder simply
    // stays until the next launch has a connection.
    if (!Api.instance.isReady || _inFlight.contains(path)) return;
    _inFlight.add(path);
    try {
      final bytes = await Api.instance.downloadImage(path);
      await scope.db.cacheImage(
        path: path,
        bytes: bytes,
        contentType: 'image/*',
      );
      if (mounted) setState(() => _cached = Uint8ListCache(bytes));
    } catch (_) {
      if (mounted) setState(() {});
    } finally {
      _inFlight.remove(path);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bytes = _cached?.bytes;
    final placeholder = NeutralPlaceholder(
      icon: widget.icon,
      radius: widget.radius,
    );
    if (bytes == null) {
      return SizedBox(
        width: widget.width,
        height: widget.height,
        child: placeholder,
      );
    }
    return Image.memory(
      Uint8List.fromList(bytes),
      width: widget.width,
      height: widget.height,
      fit: widget.fit,
      gaplessPlayback: true,
      errorBuilder: (context, error, stack) => SizedBox(
        width: widget.width,
        height: widget.height,
        child: placeholder,
      ),
    );
  }
}

/// Just the bytes: a tiny wrapper so the state holds one clear type.
class Uint8ListCache {
  Uint8ListCache(this.bytes);
  final List<int> bytes;
}

// ------------------------------------------------------------- skeleton loaders

/// Shimmering placeholder shown while products, orders, or reports load.
/// Replaces the bare CircularProgressIndicator so the page feels populated
/// even before data arrives.
class ProductSkeleton extends StatelessWidget {
  const ProductSkeleton({super.key});

  @override
  Widget build(BuildContext context) => PosCard(
    padding: EdgeInsets.zero,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(height: 150, color: AppColors.surfaceMid),
        Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(height: 15, width: 140, color: AppColors.surfaceMid),
              const SizedBox(height: 8),
              Container(height: 13, width: 90, color: AppColors.surfaceMid),
            ],
          ),
        ),
      ],
    ),
  );
}

/// Skeleton row for the Orders list.
class OrderSkeleton extends StatelessWidget {
  const OrderSkeleton({super.key});

  @override
  Widget build(BuildContext context) => PosCard(
    margin: const EdgeInsets.only(bottom: AppSpacing.md),
    padding: const EdgeInsets.all(AppSpacing.md),
    child: Row(
      children: [
        Container(width: 48, height: 48, color: AppColors.surfaceMid),
        const SizedBox(width: AppSpacing.md),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(height: 14, width: 200, color: AppColors.surfaceMid),
              const SizedBox(height: 6),
              Container(height: 12, width: 120, color: AppColors.surfaceMid),
            ],
          ),
        ),
        Container(height: 16, width: 100, color: AppColors.surfaceMid),
      ],
    ),
  );
}

/// Skeleton card for Reports KPI tiles.
class KpiSkeleton extends StatelessWidget {
  const KpiSkeleton({super.key});

  @override
  Widget build(BuildContext context) => PosCard(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(height: 10, width: 80, color: AppColors.surfaceMid),
        const SizedBox(height: 8),
        Container(height: 22, width: 120, color: AppColors.surfaceMid),
      ],
    ),
  );
}

/// Shimmer animation controller shared by skeleton loaders.
class _Shimmer extends StatefulWidget {
  const _Shimmer({required this.child});

  final Widget child;

  @override
  State<_Shimmer> createState() => _ShimmerState();
}

class _ShimmerState extends State<_Shimmer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Design §2.10: reduced motion gets a static skeleton, not a loop.
    // didChangeDependencies runs before every build, so an OS setting
    // flipped mid-session also takes effect on the next frame.
    final animate = posMotion(context);
    if (animate && !_controller.isAnimating) {
      _controller.repeat(reverse: true);
    } else if (!animate && _controller.isAnimating) {
      _controller.stop();
      _controller.value = 0.5;
    }
  }

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
      value: 0.5,
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _controller,
    builder: (context, child) {
      final t = _controller.value;
      return ShaderMask(
        shaderCallback: (bounds) => LinearGradient(
          colors: [
            AppColors.surfaceMid,
            AppColors.surfaceHi.withValues(alpha: 0.6),
            AppColors.surfaceMid,
          ],
          stops: [t - 0.3, t, t + 0.3],
          tileMode: TileMode.clamp,
        ).createShader(bounds),
        blendMode: BlendMode.srcATop,
        child: child,
      );
    },
    child: widget.child,
  );
}

/// Wraps any widget in the shimmer effect.
class Shimmer extends StatelessWidget {
  const Shimmer({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => _Shimmer(child: child);
}

/// W4: "Install this app" banner shown once on devices that can install the
/// PWA but haven't yet. Dismissed after the user taps Install or Close.
class PwaInstallBanner extends StatefulWidget {
  const PwaInstallBanner({super.key});

  @override
  State<PwaInstallBanner> createState() => _PwaInstallBannerState();
}

class _PwaInstallBannerState extends State<PwaInstallBanner> {
  bool _dismissed = false;
  bool _installing = false;

  @override
  void initState() {
    super.initState();
    web.PwaInstallPrompt.instance.listen();
  }

  Future<void> _install() async {
    setState(() => _installing = true);
    final ok = await web.PwaInstallPrompt.instance.show();
    if (!mounted) return;
    if (ok) {
      setState(() => _dismissed = true);
    } else {
      setState(() => _installing = false);
      showSnack(context, 'Install prompt not available on this browser.');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_dismissed || !web.PwaInstallPrompt.instance.isAvailable) {
      return const SizedBox.shrink();
    }
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.surfaceLow,
        border: Border.all(color: AppColors.line),
        borderRadius: BorderRadius.circular(AppRadius.m),
      ),
      child: Row(
        children: [
          const Icon(AppIcons.tablet, size: 20, color: AppColors.primary),
          const SizedBox(width: 10),
          const Expanded(
            child: Text(
              'Install STAR:DOM POS on this iPad for full-screen, app-like use.',
              style: TextStyle(
                fontWeight: FontWeight.w700,
                fontSize: 12.5,
                color: AppColors.ink,
              ),
            ),
          ),
          const SizedBox(width: 10),
          if (_installing)
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else ...[
            TextButton(
              onPressed: () => setState(() => _dismissed = true),
              child: const Text('Close', style: TextStyle(fontSize: 12)),
            ),
            const SizedBox(width: 8),
            PosButton(
              label: 'Install',
              icon: AppIcons.tablet,
              expanded: false,
              height: 36,
              busy: _installing,
              variant: PosButtonVariant.ghost,
              onPressed: _install,
            ),
          ],
        ],
      ),
    );
  }
}
