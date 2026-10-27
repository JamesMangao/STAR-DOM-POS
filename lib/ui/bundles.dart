import 'package:flutter/material.dart';

import '../core/icons.dart';
import '../core/format.dart';
import '../core/tokens.dart';
import '../data/catalogue.dart';
import '../data/db.dart';
import '../data/logic.dart';
import 'adaptive.dart';
import 'scope.dart';
import 'widgets.dart';

/// Settings → PROMO BUNDLES.
///
/// The owner's deals ("any 4 stickers for ₱100"). Until now they were
/// compiled into the app bundle from catalogue.json, so changing one meant a
/// redeploy. They now live in the synced `settings` table under
/// [BundleRulesCodec.key]: this screen writes the row, the cart re-reads it
/// immediately, sync carries it to the server (and the other devices), and a
/// site-data clear brings it back with the pull.
class BundleRulesScreen extends StatefulWidget {
  const BundleRulesScreen({super.key});

  @override
  State<BundleRulesScreen> createState() => _BundleRulesScreenState();
}

class _BundleRulesScreenState extends State<BundleRulesScreen> {
  List<BundleRule> _rules = const [];
  List<Category> _categories = const [];
  bool _started = false;
  bool _saving = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    _load();
  }

  Future<void> _load() async {
    final scope = PosScope.read(context);
    final categories = await scope.db.listCategories(scope.store);
    if (!mounted) return;
    setState(() {
      _rules = List.of(scope.cart.bundleRules);
      _categories = categories;
    });
  }

  String? _categoryName(String id) {
    for (final c in _categories) {
      if (c.id == id) return c.name;
    }
    return null;
  }

  /// The one write path: settings row + the live cart, in that order, so the
  /// Sell screen's hint bar updates before the snack even shows.
  Future<void> _persist() async {
    final scope = PosScope.read(context);
    final device = await scope.devices.ensureRegistered(scope.store);
    await scope.db.setSetting(
      scope.store,
      BundleRulesCodec.key,
      BundleRulesCodec.encode(_rules),
      deviceId: device.id,
    );
    scope.cart.bundleRules = _rules;
  }

  Future<void> _announce(String message) async {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            message,
            style: jakarta(13, color: AppColors.onPrimary),
          ),
          backgroundColor: AppColors.ink,
        ),
      );
  }

  Future<void> _openForm({BundleRule? rule}) async {
    final edited = await Navigator.of(context).push<BundleRule>(
      MaterialPageRoute<BundleRule>(
        builder: (_) =>
            BundleRuleFormScreen(rule: rule, categories: _categories),
      ),
    );
    if (edited == null || !mounted) return;
    setState(() {
      _rules = [
        for (final r in _rules)
          if (!identical(r, rule) && !identical(r, edited)) r,
        edited,
      ];
    });
    setState(() => _saving = true);
    try {
      await _persist();
      await _announce(
        'Saved — “${edited.name}” is live on this booth and syncing.',
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _remove(BundleRule rule) async {
    final confirmed = await confirm(
      context,
      title: 'Delete “${rule.name}”?',
      message:
          'The deal stops applying to carts right away. You can add it back '
          'any time.',
      confirmLabel: 'Delete',
      danger: true,
    );
    if (confirmed != true || !mounted) return;
    setState(
      () => _rules = [
        for (final r in _rules)
          if (!identical(r, rule)) r,
      ],
    );
    setState(() => _saving = true);
    try {
      await _persist();
      await _announce('Deleted — “${rule.name}” no longer applies.');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _restoreDefaults() async {
    setState(() => _saving = true);
    try {
      final catalogue = await Catalogue.load();
      setState(() => _rules = List.of(catalogue.bundleRules));
      await _persist();
      await _announce('Catalogue defaults restored and synced.');
    } catch (e) {
      await _announce('Could not read the catalogue deals: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Promo bundles'),
        actions: const [
          Padding(
            padding: EdgeInsets.only(right: 12),
            child: Center(child: SyncChip()),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _saving ? null : () => _openForm(),
        icon: const Icon(AppIcons.plus),
        label: const Text('Add deal'),
      ),
      body: _rules.isEmpty
          ? const EmptyState(
              icon: AppIcons.discount,
              title: 'No bundle deals',
              message:
                  'Add a deal like “any 4 stickers for ₱100” — the Sell '
                  'screen announces it and applies it to the cart '
                  'automatically.',
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
                  for (final rule in _rules) _row(rule),
                  const SizedBox(height: AppSpacing.sm),
                  Text(
                    'Deals sync to the server — editing on this booth updates '
                    'every signed-in device, and they survive a site-data '
                    'clear.',
                    style: jakarta(11.5, color: AppColors.inkFaint),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  PosButton(
                    label: 'Restore catalogue defaults',
                    icon: AppIcons.refresh,
                    variant: PosButtonVariant.quiet,
                    busy: _saving,
                    onPressed: _restoreDefaults,
                  ),
                ],
              ),
            ),
    );
  }

  Widget _row(BundleRule rule) {
    final chipNames = [
      for (final id in rule.categoryIds)
        if (_categoryName(id) case final String name) name,
    ];
    return PosCard(
      margin: const EdgeInsets.only(bottom: AppSpacing.md),
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.sm,
      ),
      onTap: () => _openForm(rule: rule),
      child: Row(
        children: [
          const Icon(AppIcons.discount, size: 22, color: AppColors.primary),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  rule.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: sora(14.5, weight: FontWeight.w700),
                ),
                const SizedBox(height: 3),
                Text(
                  'Any ${rule.quantity} for ${Fmt.peso(rule.price)}',
                  style: jakarta(
                    12.5,
                    weight: FontWeight.w600,
                    color: AppColors.primary,
                  ),
                ),
                if (chipNames.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: [
                      for (final name in chipNames)
                        StatusBadge(name, kind: BadgeKind.neutral),
                    ],
                  ),
                ],
              ],
            ),
          ),
          IconButton(
            tooltip: 'Delete deal',
            onPressed: () => _remove(rule),
            icon: const Icon(AppIcons.delete, size: 20),
            color: AppColors.inkFaint,
          ),
        ],
      ),
    );
  }
}

/// Add / edit one deal: name, how many items, the set price and which
/// shelves it applies to.
class BundleRuleFormScreen extends StatefulWidget {
  const BundleRuleFormScreen({super.key, this.rule, required this.categories});

  final BundleRule? rule;
  final List<Category> categories;

  @override
  State<BundleRuleFormScreen> createState() => _BundleRuleFormScreenState();
}

class _BundleRuleFormScreenState extends State<BundleRuleFormScreen> {
  final _name = TextEditingController();
  final _quantity = TextEditingController();
  final _price = TextEditingController();
  Set<String> _categoryIds = {};
  String? _error;
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    final r = widget.rule;
    if (r != null) {
      _name.text = r.name;
      _quantity.text = r.quantity.toString();
      _price.text = r.price.toStringAsFixed(2);
      _categoryIds = Set.of(r.categoryIds);
    } else {
      _quantity.text = '4';
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _quantity.dispose();
    _price.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _name.text.trim();
    final quantity = int.tryParse(_quantity.text.trim());
    final price = double.tryParse(_price.text.trim());
    if (name.isEmpty) {
      setState(() => _error = 'Give the deal a name the receipt can print.');
      return;
    }
    if (quantity == null || quantity < 2) {
      setState(() => _error = 'A bundle needs at least 2 items.');
      return;
    }
    if (price == null || price < 0) {
      setState(() => _error = 'Enter the bundle price, e.g. 100.');
      return;
    }
    if (_categoryIds.isEmpty) {
      setState(() => _error = 'Pick at least one shelf the deal applies to.');
      return;
    }
    Navigator.of(context).pop(
      BundleRule(
        name: name,
        quantity: quantity,
        price: Money.round(price),
        categoryIds: Set.of(_categoryIds),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.rule == null ? 'Add deal' : 'Edit deal'),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: Adaptive.formMax),
          child: ListView(
            padding: const EdgeInsets.all(AppSpacing.screen),
            children: [
              Text(
                'The deal the Sell screen announces and applies: “any N of '
                'these shelves for one price.”',
                style: jakarta(12.5, color: AppColors.inkSoft),
              ),
              const SizedBox(height: AppSpacing.md),
              PosField(
                label: 'Deal name',
                controller: _name,
                required: true,
                hint: 'e.g. Stickers Bundle',
              ),
              PosField(
                label: 'Items in one bundle',
                controller: _quantity,
                required: true,
                keyboardType: TextInputType.number,
                hint: 'e.g. 4',
              ),
              PosField(
                label: 'Bundle price (₱)',
                controller: _price,
                required: true,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                hint: 'e.g. 100 — what the whole set costs',
              ),
              const SizedBox(height: AppSpacing.sm),
              Text(
                'Applies to these shelves',
                style: sora(
                  12,
                  weight: FontWeight.w700,
                  color: AppColors.inkSoft,
                ),
              ),
              const SizedBox(height: AppSpacing.xs),
              Wrap(
                spacing: AppSpacing.xs,
                runSpacing: AppSpacing.xs,
                children: [
                  for (final c in widget.categories)
                    FilterChip(
                      label: Text(c.name, style: jakarta(12.5)),
                      selected: _categoryIds.contains(c.id),
                      onSelected: (on) => setState(() {
                        if (on) {
                          _categoryIds.add(c.id);
                        } else {
                          _categoryIds.remove(c.id);
                        }
                      }),
                      selectedColor: AppColors.yellowSoft,
                      checkmarkColor: AppColors.primary,
                      side: const BorderSide(color: AppColors.line),
                    ),
                ],
              ),
              if (_error != null) ...[
                const SizedBox(height: AppSpacing.md),
                PosAlert.err(text: _error!),
              ],
              const SizedBox(height: AppSpacing.lg),
              PosButton(
                label: widget.rule == null ? 'Add deal' : 'Save deal',
                icon: AppIcons.check,
                onPressed: _submit,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
