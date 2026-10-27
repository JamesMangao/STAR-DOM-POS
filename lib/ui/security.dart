import 'package:flutter/material.dart';

import '../core/tokens.dart';
import '../data/db.dart';
import 'scope.dart';
import 'widgets.dart';

/// The Booth void gate.
///
/// The owner sets a 4–6 digit PIN in Settings → Security (for multiple (per-booth)
/// discounts that could be abused) — one synced setting, store-wide — and from then
/// on EVERY void of an order anywhere (Receipt screen, Orders long-press menu) asks
/// for it first. One code, synced to every booth like the bundle rules, so offline
/// booths enforce the same gate without a round trip.
///
/// Gate off = the setting is absent or empty: the owner chose it, so a booth with
/// no PIN voids with the reason prompt only, exactly as before.
class VoidPin {
  VoidPin._();

  /// The settings-row key. One per store, value = the digits (emptyString clears).
  static const key = 'void_pin';

  static bool isValid(String pin) =>
      pin.length >= 4 &&
      pin.length <= 6 &&
      pin.contains(RegExp(r'\D')) == false;
}

/// Returns the gate's stored PIN (empty when the gate is off).
Future<String> voidPinOf(AppDatabase db, String storeId) =>
    db.getSetting(storeId, VoidPin.key).then((s) => s?.value ?? '');

/// True when the current user may continue into a void: the gate is off, or
/// they entered the right code within three tries. Cancel backs out.
Future<bool> voidPinAllowed(
  BuildContext context,
  AppDatabase db,
  String storeId,
) async {
  final stored = await voidPinOf(db, storeId);
  if (stored.isEmpty) return true;
  for (var attempt = 0; attempt < 3; attempt++) {
    if (!context.mounted) return false;
    final entered = await _askVoidPin(context, wrong: attempt > 0);
    if (entered == null) return false; // cancelled
    if (entered == stored) return true;
  }
  if (context.mounted) {
    showSnack(context, 'Three wrong tries — void cancelled.', error: true);
  }
  return false;
}

Future<String?> _askVoidPin(BuildContext context, {required bool wrong}) {
  final controller = TextEditingController();
  return showDialog<String>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => AlertDialog(
      backgroundColor: AppColors.card,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.xl),
        side: const BorderSide(color: AppColors.lineHi),
      ),
      title: Text(
        wrong ? 'Wrong PIN — try again' : 'Enter the Void PIN',
        style: sora(18, weight: FontWeight.w800),
      ),
      content: TextField(
        controller: controller,
        autofocus: true,
        obscureText: true,
        keyboardType: TextInputType.number,
        maxLength: 6,
        style: mono(18, weight: FontWeight.w700),
        textInputAction: TextInputAction.done,
        onSubmitted: (v) => Navigator.of(ctx).pop(v.trim()),
        decoration: const InputDecoration(
          labelText: 'PIN (4–6 digits)',
          counterText: '',
        ),
      ),
      actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(null),
          child: Text('Cancel', style: sora(13, color: AppColors.inkSoft)),
        ),
        PosButton(
          label: 'Unlock',
          expanded: false,
          height: 44,
          onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
        ),
      ],
    ),
  );
}

/// Settings → Security: set, change or remove the store's Void PIN. A null
/// return means the owner backed out without touching anything;'' clears the
/// gate, otherwise [VoidPin.isValid] digits are written as one synced setting.
/// Returns the new stored value so the Settings row can redraw.
Future<String?> editVoidPin(BuildContext context) async {
  final scope = PosScope.read(context);
  final device = await scope.devices.ensureRegistered(scope.store);
  if (!context.mounted) return null;
  final controller = TextEditingController();
  final value = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: AppColors.card,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.xl),
        side: const BorderSide(color: AppColors.lineHi),
      ),
      title: Text('Set Void PIN', style: sora(18, weight: FontWeight.w800)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Asked before every void, on every booth. Leave empty to switch '
            'the gate off.',
            style: jakarta(14, color: AppColors.inkSoft),
          ),
          const SizedBox(height: AppSpacing.md),
          TextField(
            controller: controller,
            autofocus: true,
            obscureText: true,
            keyboardType: TextInputType.number,
            maxLength: 6,
            style: mono(18, weight: FontWeight.w700),
            textInputAction: TextInputAction.done,
            onSubmitted: (v) => Navigator.of(ctx).pop(v.trim()),
            decoration: const InputDecoration(
              labelText: 'New PIN (empty removes it)',
              counterText: '',
            ),
          ),
        ],
      ),
      actionsPadding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(null),
          child: Text('Cancel', style: sora(13, color: AppColors.inkSoft)),
        ),
        PosButton(
          label: 'Save',
          expanded: false,
          height: 44,
          onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
        ),
      ],
    ),
  );
  controller.dispose();
  if (value == null) return null; // cancelled, no change
  if (value.isNotEmpty && !VoidPin.isValid(value)) {
    if (context.mounted) {
      showSnack(context, 'PIN must be 4–6 digits.', error: true);
    }
    return null;
  }
  // Empty clears the gate; otherwise the digits become the store's PIN.
  await scope.db.setSetting(
    scope.store,
    VoidPin.key,
    value,
    deviceId: device.id,
  );
  await scope.sync.syncAll();
  return value;
}
