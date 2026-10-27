import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../core/icons.dart';
import '../core/tokens.dart';
import '../core/web_apis.dart' as web;
import '../data/api.dart';
import '../data/db.dart';
import 'adaptive.dart';
import 'scope.dart';
import 'widgets.dart';

/// Settings → PAYMENT METHODS.
///
/// Cash plus the wallet QR methods the booth actually takes. Everything here
/// mirrors to the other devices through the outbox, so adding GCash on the
/// owner's phone makes it tappable on the iPad after one sync.
class PaymentMethodsScreen extends StatefulWidget {
  const PaymentMethodsScreen({super.key});

  @override
  State<PaymentMethodsScreen> createState() => _PaymentMethodsScreenState();
}

class _PaymentMethodsScreenState extends State<PaymentMethodsScreen> {
  List<PaymentMethod> _methods = const [];
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    _load();
  }

  Future<void> _load() async {
    final scope = PosScope.read(context);
    final rows = await scope.db.listPaymentMethods(scope.store);
    if (!mounted) return;
    setState(() => _methods = rows);
  }

  Future<void> _openForm({PaymentMethod? method}) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PaymentMethodFormScreen(method: method),
      ),
    );
    if (mounted) _load();
  }

  Future<void> _toggle(PaymentMethod m) async {
    final scope = PosScope.read(context);
    final device = await scope.devices.ensureRegistered(scope.store);
    await scope.db.upsertPaymentMethod(
      m.copyWith(isEnabled: !m.isEnabled, updatedAt: DateTime.now().toUtc()),
      deviceId: device.id,
      storeId: scope.store,
    );
    await _load();
  }

  /// Reorder by swapping sort_order with the neighbour — the list reads
  /// ascending, so this is exactly the visible order.
  Future<void> _move(int index, int step) async {
    final target = index + step;
    if (target < 0 || target >= _methods.length) return;
    final a = _methods[index];
    final b = _methods[target];
    final scope = PosScope.read(context);
    final device = await scope.devices.ensureRegistered(scope.store);
    final now = DateTime.now().toUtc();
    await scope.db.upsertPaymentMethod(
      a.copyWith(sortOrder: b.sortOrder, updatedAt: now),
      deviceId: device.id,
      storeId: scope.store,
    );
    await scope.db.upsertPaymentMethod(
      b.copyWith(sortOrder: a.sortOrder, updatedAt: now),
      deviceId: device.id,
      storeId: scope.store,
    );
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Payment methods'),
        actions: const [
          Padding(
            padding: EdgeInsets.only(right: 12),
            child: Center(child: SyncChip()),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _openForm(),
        icon: const Icon(AppIcons.plus),
        label: const Text('Add method'),
      ),
      body: _methods.isEmpty
          ? const EmptyState(
              icon: AppIcons.cash,
              title: 'No payment methods',
              message:
                  'Add Cash first, then the GCash and GoTyme QR methods the '
                  'booth takes.',
            )
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.screen,
                  AppSpacing.sm,
                  AppSpacing.screen,
                  88,
                ),
                children: [
                  for (var i = 0; i < _methods.length; i++)
                    _row(_methods[i], i),
                ],
              ),
            ),
    );
  }

  Widget _row(PaymentMethod m, int index) {
    return PosCard(
      margin: const EdgeInsets.only(bottom: AppSpacing.md),
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.sm,
      ),
      onTap: () => _openForm(method: m),
      child: Row(
        children: [
          Icon(
            m.type == 'cash' ? AppIcons.cash : AppIcons.wallet,
            size: 22,
            color: m.isEnabled ? AppColors.primary : AppColors.inkFaint,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  m.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: sora(
                    14.5,
                    weight: FontWeight.w700,
                    color: m.isEnabled ? AppColors.ink : AppColors.inkFaint,
                  ),
                ),
                const SizedBox(height: 3),
                Row(
                  children: [
                    StatusBadge(
                      m.type == 'cash' ? 'Cash' : 'E-wallet',
                      kind: m.type == 'cash'
                          ? BadgeKind.info
                          : BadgeKind.neutral,
                    ),
                    if (m.type != 'cash') ...[
                      const SizedBox(width: 6),
                      StatusBadge(
                        (m.qrImagePath ?? '').isEmpty ? 'No QR' : 'QR ready',
                        kind: (m.qrImagePath ?? '').isEmpty
                            ? BadgeKind.pending
                            : BadgeKind.synced,
                      ),
                    ],
                    if (m.requireReference) ...[
                      const SizedBox(width: 6),
                      const StatusBadge('Ref #', kind: BadgeKind.neutral),
                    ],
                  ],
                ),
              ],
            ),
          ),
          Column(
            children: [
              IconButton(
                tooltip: 'Move up',
                onPressed: index == 0 ? null : () => _move(index, -1),
                icon: const Icon(Icons.keyboard_arrow_up, size: 22),
              ),
              IconButton(
                tooltip: 'Move down',
                onPressed: index == _methods.length - 1
                    ? null
                    : () => _move(index, 1),
                icon: const Icon(Icons.keyboard_arrow_down, size: 22),
              ),
            ],
          ),
          Switch(
            value: m.isEnabled,
            activeTrackColor: AppColors.primary,
            onChanged: (_) => _toggle(m),
          ),
        ],
      ),
    );
  }
}

/// Add / edit one method: name, cash-vs-wallet, account details, the QR
/// picture and whether the reference number is mandatory.
class PaymentMethodFormScreen extends StatefulWidget {
  const PaymentMethodFormScreen({super.key, this.method});

  final PaymentMethod? method;

  @override
  State<PaymentMethodFormScreen> createState() =>
      _PaymentMethodFormScreenState();
}

class _PaymentMethodFormScreenState extends State<PaymentMethodFormScreen> {
  final _name = TextEditingController();
  final _accountName = TextEditingController();
  final _accountNumber = TextEditingController();
  String _type = 'cash';
  String? _qrPath;
  bool _requireReference = false;
  bool _saving = false;
  bool _qrBusy = false;
  String? _error;
  bool _started = false;

  String get _id => widget.method?.id ?? const Uuid().v4();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    final m = widget.method;
    if (m != null) {
      _name.text = m.name;
      _type = m.type;
      _qrPath = m.qrImagePath;
      _accountName.text = m.accountName;
      _accountNumber.text = m.accountNumber;
      _requireReference = m.requireReference;
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _accountName.dispose();
    _accountNumber.dispose();
    super.dispose();
  }

  Future<void> _pickQr() async {
    if (_qrBusy) return;
    final picked = await web.pickImage(maxDimension: 800);
    if (picked == null || !mounted) return;
    if (!Api.instance.isReady) {
      showSnack(
        context,
        'Uploading a QR code needs an internet connection.',
        error: true,
      );
      return;
    }
    setState(() => _qrBusy = true);
    final scope = PosScope.read(context);
    final ext = switch (picked.mime) {
      'image/png' => 'png',
      'image/jpeg' => 'jpg',
      _ => 'webp',
    };
    final path = 'qr/$_id.$ext';
    try {
      await Api.instance.uploadImage(path, picked.bytes, picked.mime);
      await scope.db.cacheImage(
        path: path,
        bytes: picked.bytes,
        contentType: picked.mime,
      );
      if (!mounted) return;
      setState(() {
        _qrPath = path;
        _qrBusy = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _qrBusy = false);
      showSnack(context, 'The QR code could not be uploaded.', error: true);
    }
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'The method needs a name the cashier knows.');
      return;
    }
    if (_type != 'cash' && (_qrPath ?? '').isEmpty) {
      setState(() => _error = 'Upload the QR code before saving this wallet.');
      return;
    }
    final scope = PosScope.read(context);
    // Refuse a NORMALISED duplicate name at the form — the server's unique
    // index (migration 006) would reject the push anyway.
    final dup = await scope.db.livePaymentMethodByName(
      scope.store,
      name,
      excludeId: _id,
    );
    if (!mounted) return;
    if (dup != null) {
      setState(
        () => _error =
            '“${dup.name}” already exists — pick a different '
            'name for this method.',
      );
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final device = await scope.devices.ensureRegistered(scope.store);
    final m = widget.method;
    final now = DateTime.now().toUtc();
    final updated = PaymentMethod(
      id: _id,
      storeId: scope.store,
      name: name,
      type: _type,
      color: m?.color ?? (_type == 'cash' ? '#B70011' : '#15803D'),
      qrImagePath: _type == 'cash' ? null : _qrPath,
      accountName: _accountName.text.trim(),
      accountNumber: _accountNumber.text.trim(),
      requireReference: _type == 'cash' ? false : _requireReference,
      isEnabled: m?.isEnabled ?? true,
      sortOrder: m?.sortOrder ?? 0,
      createdAt: m?.createdAt ?? now,
      updatedAt: now,
      deletedAt: null,
      syncedAt: null,
    );
    await scope.db.upsertPaymentMethod(
      updated,
      deviceId: device.id,
      storeId: scope.store,
    );
    await scope.sync.syncAll();
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  Future<void> _delete() async {
    final yes = await confirm(
      context,
      title: 'Delete ${widget.method?.name ?? 'this method'}?',
      message:
          'It disappears from the Cart screen. Past sales keep their payment '
          'snapshot — receipts never change.',
      confirmLabel: 'Delete',
      danger: true,
    );
    if (!yes || !mounted) return;
    final scope = PosScope.read(context);
    final device = await scope.devices.ensureRegistered(scope.store);
    await scope.db.softDeletePaymentMethod(
      _id,
      deviceId: device.id,
      storeId: scope.store,
    );
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final isWallet = _type != 'cash';
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.method == null ? 'New method' : 'Edit method'),
      ),
      body: CenteredWidth(
        child: ListView(
          padding: const EdgeInsets.all(AppSpacing.screen),
          children: [
            PosField(
              label: 'Name',
              controller: _name,
              required: true,
              hint: 'e.g. GCash',
            ),
            SectionCard(
              title: 'Type',
              children: [
                Row(
                  children: [
                    Expanded(
                      child: PosButton(
                        label: 'Cash',
                        icon: AppIcons.cash,
                        variant: _type == 'cash'
                            ? PosButtonVariant.primary
                            : PosButtonVariant.ghost,
                        onPressed: () => setState(() => _type = 'cash'),
                      ),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      child: PosButton(
                        label: 'E-wallet',
                        icon: AppIcons.wallet,
                        variant: isWallet
                            ? PosButtonVariant.primary
                            : PosButtonVariant.ghost,
                        onPressed: () => setState(() => _type = 'wallet'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
            if (isWallet) ...[
              SectionCard(
                title: 'QR code',
                children: [
                  Row(
                    children: [
                      SizedBox(
                        width: 84,
                        height: 84,
                        child: StorageImage(
                          path: _qrPath,
                          radius: AppRadius.m,
                          icon: AppIcons.qr,
                        ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: PosButton(
                          label: _qrBusy ? 'Uploading…' : 'Upload QR',
                          icon: AppIcons.upload,
                          variant: PosButtonVariant.ghost,
                          busy: _qrBusy,
                          onPressed: _pickQr,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Photograph or save the wallet\'s QR image, then upload it '
                    'here. The cashier shows it full-screen while the customer '
                    'pays.',
                    style: jakarta(11.5, color: AppColors.inkSoft),
                  ),
                ],
              ),
              PosField(
                label: 'Account name',
                controller: _accountName,
                hint: 'Shown under the QR, e.g. STAR:DOM',
              ),
              PosField(
                label: 'Account number',
                controller: _accountNumber,
                hint: 'Optional',
                keyboardType: TextInputType.phone,
              ),
              SwitchListTile(
                value: _requireReference,
                contentPadding: EdgeInsets.zero,
                title: Text(
                  'Require reference number',
                  style: sora(14, weight: FontWeight.w700),
                ),
                subtitle: Text(
                  'The sale cannot complete without the customer\'s '
                  'confirmation code.',
                  style: jakarta(12, color: AppColors.inkSoft),
                ),
                onChanged: (v) => setState(() => _requireReference = v),
              ),
            ],
            if (_error != null) ...[
              PosAlert.err(text: _error!),
              const SizedBox(height: AppSpacing.md),
            ],
            PosButton(
              label: 'Save method',
              icon: AppIcons.check,
              busy: _saving,
              onPressed: _save,
            ),
            if (widget.method != null) ...[
              const SizedBox(height: AppSpacing.sm),
              PosButton(
                label: 'Delete method',
                icon: AppIcons.delete,
                variant: PosButtonVariant.danger,
                onPressed: _delete,
              ),
            ],
            const SizedBox(height: AppSpacing.xl),
          ],
        ),
      ),
    );
  }
}
