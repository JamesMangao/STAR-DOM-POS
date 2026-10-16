import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import 'core/env.dart';
import 'core/theme.dart';
import 'core/tokens.dart';
import 'core/web_apis.dart' as web;
import 'data/api.dart';
import 'data/auth.dart';
import 'data/db.dart';
import 'data/db_open.dart';
import 'data/device.dart';
import 'data/sync.dart';

/// STAR:DOM POS — single-owner booth POS, installed as a PWA.
///
/// This is the SHELL: it boots the local database, the session, the sync engine
/// and the device rules (persistent storage, wake lock, the unsynced-sales
/// guard). The selling/cart/receipt screens are Part B and are deliberately not
/// here.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final opened = await openAppDatabase();

  // W2: ask for persistent storage BEFORE anything is sold, and remember the
  // answer. WebKit evicts non-persistent origins under memory pressure, and
  // every unsynced sale would go with it.
  final persisted = await web.requestPersistentStorage();

  if (Env.isConfigured) {
    await Api.instance.init();
    await OwnerAuth.instance.init();
  }

  runApp(StardomApp(opened: opened, storagePersisted: persisted));
}

class StardomApp extends StatefulWidget {
  const StardomApp({
    super.key,
    required this.opened,
    required this.storagePersisted,
  });

  final DatabaseOpenResult opened;
  final bool storagePersisted;

  @override
  State<StardomApp> createState() => _StardomAppState();
}

class _StardomAppState extends State<StardomApp> {
  late final AppDatabase _db = widget.opened.db;
  late final DeviceRegistry _devices = DeviceRegistry(_db);
  late final SyncEngine _sync = SyncEngine(_db, _devices);

  String? _storeId;
  bool _booting = true;

  @override
  void initState() {
    super.initState();
    unawaited(_boot());
  }

  Future<void> _boot() async {
    final stores = await _db.allStores();
    if (stores.length == 1) {
      _storeId = stores.first.id;
      await _db.setLocalSetting(
        _storeId!,
        'storage_persisted',
        widget.storagePersisted ? 'yes' : 'no',
      );
      _sync.start(_storeId!);
      unawaited(_sync.syncAll());
    }
    if (!mounted) return;
    setState(() => _booting = false);
  }

  @override
  void dispose() {
    _sync.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Stardom POS',
      theme: AppTheme.light(),
      debugShowCheckedModeBanner: false,
      home: _booting
          ? const Scaffold(body: Center(child: CircularProgressIndicator()))
          : _Home(
              db: _db,
              sync: _sync,
              storeId: _storeId,
              opened: widget.opened,
            ),
    );
  }
}

/// The shell: session chip, unsynced-sales guard, device rules, export.
class _Home extends StatefulWidget {
  const _Home({
    required this.db,
    required this.sync,
    required this.storeId,
    required this.opened,
  });

  final AppDatabase db;
  final SyncEngine sync;
  final String? storeId;
  final DatabaseOpenResult opened;

  @override
  State<_Home> createState() => _HomeState();
}

class _HomeState extends State<_Home> with WidgetsBindingObserver {
  SyncState _state = SyncState.offline;
  int _pending = 0;
  Duration? _oldest;
  int _imageCount = 0;
  int _imageBytes = 0;

  /// The answer `navigator.storage.persist()` gave on this install, as recorded
  /// at boot ('yes' / 'no' / 'unknown'), shown in Settings and on
  /// `window.__stardomBootInfo`.
  String _storagePersisted = 'unknown';
  Timer? _ticker;

  /// A pending sale older than this is a real risk, not a slow network.
  static const Duration staleAfter = Duration(hours: 24);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.sync.stateStream.listen((s) => setState(() => _state = s));
    unawaited(refresh());
    _ticker = Timer.periodic(const Duration(seconds: 10), (_) => refresh());
  }

  @override
  void dispose() {
    _ticker?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Device rule: keep the screen awake while the app is visible, and let the
    // browser take the lock back the moment it is not.
    if (state == AppLifecycleState.resumed) {
      unawaited(web.acquireWakeLock());
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      unawaited(web.releaseWakeLock());
    }
  }

  Future<void> refresh() async {
    final storeId = widget.storeId;
    if (storeId != null) {
      final pending = await widget.db.pendingCount(storeId);
      final oldestAt = await widget.db.oldestPendingAt(storeId);
      final images = await widget.db.cachedImageCount();
      final bytes = await widget.db.cachedImageBytes();
      final persisted = await widget.db.getSetting(
        storeId,
        'storage_persisted',
      );
      if (!mounted) return;
      setState(() {
        _storagePersisted = persisted?.value ?? 'unknown';
        _pending = pending;
        _oldest = oldestAt == null
            ? null
            : DateTime.now().toUtc().difference(oldestAt);
        _imageCount = images;
        _imageBytes = bytes;
      });
    }
    // Published even with NO store row: a fresh install must still be able to
    // report which storage backend it got, which is the whole point of the
    // device rule (report it, never assume it).
    _publishBootInfo();
  }

  /// The facts an operator (or scripts/offline-test.js) needs to know about an
  /// installed PWA. No secrets: mode, persistence, counts, session flag.
  void _publishBootInfo() {
    web.setBootInfo(
      jsonEncode({
        'storageMode': widget.opened.storageMode,
        'persistent': widget.opened.persistent,
        'storagePersisted': _storagePersisted,
        'missingFeatures': widget.opened.missingFeatures,
        'storeId': widget.storeId,
        'pendingSales': _pending,
        'imagesCached': _imageCount,
        'signedIn': OwnerAuth.instance.signedIn,
        'configured': Env.isConfigured,
      }),
    );
  }

  bool get _stale => _pending > 0 && (_oldest ?? Duration.zero) > staleAfter;

  Future<void> _exportData() async {
    final dump = await widget.db.exportAll();
    final stamp = DateTime.now().toUtc().toIso8601String().substring(0, 10);
    web.downloadFile(
      'stardom-pos-export-$stamp.json',
      'application/json',
      utf8.encode(const JsonEncoder.withIndent('  ').convert(dump)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('STAR:DOM POS'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Center(
              child: _SyncChip(state: _state, pending: _pending),
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (_stale) const _DataLossBanner(),
          if (widget.storeId == null) const _NotSeededCard(),
          if (widget.storeId != null) ...[
            _SettingsCard(
              children: [
                _Row('Storage', widget.opened.description),
                _Row(
                  'Persistent storage',
                  '$_storagePersisted (browser support: '
                      '${widget.opened.persistent ? 'yes' : 'no'})',
                ),
                _Row(
                  'Images cached offline',
                  '$_imageCount (${(_imageBytes / 1024).round()} KB)',
                ),
                if (widget.opened.missingFeatures.isNotEmpty)
                  _Row(
                    'Browser limits',
                    widget.opened.missingFeatures.join(', '),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            _SettingsCard(
              children: [
                _Row('Pending sales', '$_pending'),
                _Row(
                  'Oldest pending',
                  _oldest == null ? '—' : _human(_oldest!),
                ),
                _Row(
                  'Session',
                  OwnerAuth.instance.signedIn
                      ? 'signed in (sync enabled)'
                      : 'signed out — selling still works',
                ),
              ],
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: widget.sync.syncAll,
              icon: const Icon(Icons.sync),
              label: const Text('Sync now'),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _exportData,
              icon: const Icon(Icons.download),
              label: const Text('Export data (JSON)'),
            ),
            if (!OwnerAuth.instance.signedIn) ...[
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(builder: (_) => const SignInScreen()),
                ),
                icon: const Icon(Icons.login),
                label: const Text('Sign in to sync'),
              ),
            ],
          ],
          const SizedBox(height: 24),
          Text(
            'Shell build — the selling screens are Part B.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }

  static String _human(Duration d) {
    if (d.inHours >= 24) return '${d.inDays}d ${d.inHours % 24}h';
    if (d.inHours >= 1) return '${d.inHours}h ${d.inMinutes % 60}m';
    return '${d.inMinutes}m';
  }
}

/// W1: the ONE sign-in surface. No signup, no forgot-password, one generic
/// error, and a deliberate delay after a rejection.
class SignInScreen extends StatefulWidget {
  const SignInScreen({super.key});

  @override
  State<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends State<SignInScreen> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final outcome = await OwnerAuth.instance.signIn(
      email: _email.text,
      password: _password.text,
    );
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = outcome == SignInOutcome.ok ? null : outcome.message;
    });
    if (outcome == SignInOutcome.ok) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: BackButton(onPressed: () => Navigator.of(context).maybePop()),
        title: const Text('Sign in'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const Text('Sign in once to sync this device.'),
          const SizedBox(height: 16),
          TextField(
            controller: _email,
            keyboardType: TextInputType.emailAddress,
            autocorrect: false,
            // >=16px so Safari does not zoom the whole page on focus.
            style: const TextStyle(fontSize: 16),
            decoration: const InputDecoration(labelText: 'Owner email'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _password,
            obscureText: true,
            style: const TextStyle(fontSize: 16),
            decoration: const InputDecoration(labelText: 'Password'),
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _busy ? null : _submit,
            child: Text(_busy ? 'Signing in…' : 'Sign in'),
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!, style: TextStyle(color: AppColors.primary)),
          ],
        ],
      ),
    );
  }
}

class _SyncChip extends StatelessWidget {
  const _SyncChip({required this.state, required this.pending});

  final SyncState state;
  final int pending;

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (state) {
      SyncState.synced => ('Synced', Colors.green.shade700),
      SyncState.offline => (
        pending > 0 ? 'Offline · $pending' : 'Offline',
        Colors.orange.shade800,
      ),
      SyncState.failed => ('Failed · $pending', AppColors.primary),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontWeight: FontWeight.w700,
          fontSize: 12,
        ),
      ),
    );
  }
}

/// W2 data-loss guard.
class _DataLossBanner extends StatelessWidget {
  const _DataLossBanner();

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.primary.withValues(alpha: 0.08),
        border: Border.all(color: AppColors.primary),
        borderRadius: BorderRadius.circular(12),
      ),
      child: const Text(
        'Unsynced sales on this device. Connect to the internet and tap Sync '
        'now. Do not delete the app icon.',
        style: TextStyle(fontWeight: FontWeight.w700),
      ),
    );
  }
}

class _NotSeededCard extends StatelessWidget {
  const _NotSeededCard();

  @override
  Widget build(BuildContext context) => const Card(
    child: Padding(
      padding: EdgeInsets.all(16),
      child: Text(
        'No store yet. Run the runbook (import.js) once, then reopen the app.',
      ),
    ),
  );
}

class _SettingsCard extends StatelessWidget {
  const _SettingsCard({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: children,
      ),
    ),
  );
}

class _Row extends StatelessWidget {
  const _Row(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 140,
          child: Text(label, style: Theme.of(context).textTheme.labelMedium),
        ),
        Expanded(
          child: Text(value, style: Theme.of(context).textTheme.bodyMedium),
        ),
      ],
    ),
  );
}
