import 'dart:async';

import 'package:drift/drift.dart' show BooleanExpressionOperators;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/biz.dart';
import '../data/business_store.dart';
import '../sync/sync_engine.dart';
import '../web/browser_connector.dart';
import '../web/browser_page.dart';
import '../web/connectors.dart';
import '../web/website_sync.dart';
import 'app_state.dart';

class WebsiteStatus {
  final WebsiteConfig config;
  final bool busy;
  final WebsiteReport? last;
  final String? error;

  /// This device is the one that fetches (always true without Google Drive sync).
  final bool isPuller;
  const WebsiteStatus({this.config = const WebsiteConfig(), this.busy = false, this.last, this.error, this.isPuller = true});

  WebsiteStatus copyWith({WebsiteConfig? config, bool? busy, WebsiteReport? last, Object? error = _keep, bool? isPuller}) =>
      WebsiteStatus(
        config: config ?? this.config,
        busy: busy ?? this.busy,
        last: last ?? this.last,
        error: identical(error, _keep) ? this.error : error as String?,
        isPuller: isPuller ?? this.isPuller,
      );
  static const _keep = Object();
}

/// Fetches website orders for the open business every few minutes, and sends
/// status changes made here back to the website a moment after they happen.
class WebsiteController extends Notifier<WebsiteStatus> {
  Session? _session;
  Timer? _timer;
  Timer? _first;
  Timer? _pushSoon;
  StreamSubscription<List<int>>? _changes;
  bool _running = false;
  bool _pushAgain = false;

  @override
  WebsiteStatus build() {
    ref.onDispose(_stop);
    ref.listen(appProvider, (_, phase) {
      final s = switch (phase) {
        Ready(:final session) => session,
        Locked(:final session) => session,
        _ => null,
      };
      if (s?.biz.db == _session?.biz.db) {
        _session = s;
        return;
      }
      _stop();
      _session = s;
      if (s != null) _load(s);
    }, fireImmediately: true);
    return const WebsiteStatus();
  }

  void _stop() {
    _timer?.cancel();
    _first?.cancel();
    _pushSoon?.cancel();
    _changes?.cancel();
    _changes = null;
  }

  Future<void> _load(Session s) async {
    final cfg = await loadWebsiteConfig(s.biz);
    final lastJson = await s.biz.settings.getJson(WebKeys.last);
    if (_session != s) return;
    state = WebsiteStatus(
      config: cfg,
      last: lastJson.isEmpty ? null : WebsiteReport.fromJson(lastJson),
      isPuller: await _isPuller(s, cfg),
    );
    _schedule();
  }

  Future<bool> _isPuller(Session s, WebsiteConfig cfg) async =>
      cfg.puller == null || cfg.puller == await SyncEngine(s.biz.db).deviceId();

  void _schedule() {
    _timer?.cancel();
    _first?.cancel();
    _changes?.cancel();
    _changes = null;
    final cfg = state.config;
    final s = _session;
    if (!cfg.enabled || !cfg.ready || !state.isPuller || s == null) return;
    if (cfg.minutes > 0) {
      _timer = Timer.periodic(Duration(minutes: cfg.minutes), (_) => syncNow(quiet: true));
      _first = Timer(const Duration(seconds: 8), () => syncNow(quiet: true));
    }
    if (cfg.canPush) {
      // Website orders whose status here differs from the website's. Changes
      // made on another device arrive through Google Drive and show up here too.
      _changes = s.biz.db
          .customSelect(
            '''SELECT s.id FROM ext_links l JOIN sales s ON s.id = l.local_id
               WHERE l.kind = 'order' AND l.ext_status IS NOT NULL AND s.status <> l.ext_status''',
            readsFrom: {s.biz.db.extLinks, s.biz.db.sales},
          )
          .watch()
          .map((rows) => [for (final r in rows) r.read<int>('id')])
          .listen((ids) {
        if (ids.isEmpty) return;
        _pushSoon?.cancel();
        _pushSoon = Timer(const Duration(seconds: 2), pushNow);
      });
    }
  }

  /// Send status changes made here to the website now (no fetching).
  Future<void> pushNow() async {
    final s = _session;
    final cfg = state.config;
    if (s == null || !cfg.enabled || !cfg.ready || !cfg.canPush || !state.isPuller) return;
    if (_running) {
      _pushAgain = true;
      return;
    }
    _running = true;
    try {
      final rep = WebsiteReport();
      await WebsiteSync(s.biz, cfg.connector()).push(rep);
      if (_session == s && (rep.pushed > 0 || rep.errors.isNotEmpty)) {
        state = state.copyWith(error: rep.errors.isEmpty ? null : rep.errors.first);
      }
    } catch (e) {
      if (_session == s) state = state.copyWith(error: '$e');
    } finally {
      _running = false;
      if (_pushAgain) {
        _pushAgain = false;
        unawaited(pushNow());
      }
    }
  }

  /// Save the connection; this device becomes the one that fetches.
  Future<void> save(WebsiteConfig cfg) async {
    final s = _session;
    if (s == null) return;
    final me = await SyncEngine(s.biz.db).deviceId();
    final next = cfg.copyWith(puller: me);
    await s.biz.settings.setJson(WebKeys.config, next.toJson());
    state = state.copyWith(config: next, isPuller: true, error: null);
    _schedule();
  }

  /// Make this device the one that fetches orders.
  Future<void> takeOver() => save(state.config);

  /// The built-in browser's profile folder for the open shop.
  Future<String?> browserFolder() async {
    final s = _session;
    return s == null ? null : BusinessStore.browserDir(s.info.id);
  }

  /// A hidden browser page for reading a website through its admin panel.
  Future<HiddenPage> _hiddenPage(Session s) async {
    if (await BrowserProfile.engineVersion() == null) throw WebsiteException('no_engine');
    return HiddenPage(await BrowserProfile.environment(await BusinessStore.browserDir(s.info.id)));
  }

  /// Run [body] with the right connector for [cfg]; a hidden browser page is
  /// opened for websites read through the browser and closed afterwards.
  Future<T> _withConnector<T>(Session s, WebsiteConfig cfg, Future<T> Function(StoreConnector c) body) async {
    final hidden = cfg.isBrowser ? await _hiddenPage(s) : null;
    final conn = cfg.connector(page: hidden, unchanged: (o) => WebsiteSync.isUnchanged(s.biz, o));
    try {
      return await body(conn);
    } finally {
      if (conn is BrowserConnector) await conn.close();
      await hidden?.dispose();
    }
  }

  /// Check the address and keys without saving. Returns the website's order count.
  Future<String> test(WebsiteConfig cfg) async {
    final s = _session;
    if (s == null) return '0';
    return _withConnector(s, cfg, (c) => c.test());
  }

  /// Bring in orders pasted from a table, once.
  Future<WebsiteReport> importPasted(List<RemoteOrder> orders) async {
    final s = _session;
    if (s == null) return WebsiteReport();
    // Pasted orders come in whatever their date: the owner chose them.
    final cfg = WebsiteConfig(platform: state.config.platform);
    return WebsiteSync(s.biz, ListConnector(orders)).importOrders(orders, cfg);
  }

  Future<void> syncNow({bool quiet = false}) async {
    final s = _session;
    final cfg = state.config;
    if (s == null || _running || !cfg.ready) return;
    if (quiet && (!cfg.enabled || !state.isPuller)) return;
    _running = true;
    state = state.copyWith(busy: true);
    try {
      final rep = await _withConnector(
          s, cfg, (c) => WebsiteSync(s.biz, c).run(cfg, maxPages: cfg.isBrowser ? 400 : 20));
      if (_session == s) state = state.copyWith(busy: false, last: rep, error: null);
    } catch (e) {
      if (_session == s) state = state.copyWith(busy: false, error: '$e');
      if (!quiet) rethrow;
    } finally {
      _running = false;
      if (_pushAgain) {
        _pushAgain = false;
        unawaited(pushNow());
      }
    }
  }
}

/// The website link of an online order, if it came from the website.
final orderWebLinkProvider = StreamProvider.autoDispose.family<ExtLink?, int>((ref, saleId) {
  final db = ref.watch(bizProvider).db;
  return (db.select(db.extLinks)..where((t) => t.kind.equals('order') & t.localId.equals(saleId)))
      .watch()
      .map((rows) => rows.isEmpty ? null : rows.first);
});

final websiteProvider = NotifierProvider<WebsiteController, WebsiteStatus>(WebsiteController.new);
