import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../sync/sync_engine.dart';
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

/// Fetches website orders for the open business every few minutes.
class WebsiteController extends Notifier<WebsiteStatus> {
  Session? _session;
  Timer? _timer;
  Timer? _first;
  bool _running = false;

  @override
  WebsiteStatus build() {
    ref.onDispose(() {
      _timer?.cancel();
      _first?.cancel();
    });
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
      _timer?.cancel();
      _first?.cancel();
      _session = s;
      if (s != null) _load(s);
    }, fireImmediately: true);
    return const WebsiteStatus();
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
    final cfg = state.config;
    if (!cfg.enabled || !cfg.ready || cfg.minutes <= 0 || !state.isPuller) return;
    _timer = Timer.periodic(Duration(minutes: cfg.minutes), (_) => syncNow(quiet: true));
    _first = Timer(const Duration(seconds: 8), () => syncNow(quiet: true));
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

  /// Check the address and keys without saving. Returns the website's order count.
  Future<String> test(WebsiteConfig cfg) => cfg.connector().test();

  Future<void> syncNow({bool quiet = false}) async {
    final s = _session;
    final cfg = state.config;
    if (s == null || _running || !cfg.ready) return;
    if (quiet && (!cfg.enabled || !state.isPuller)) return;
    _running = true;
    state = state.copyWith(busy: true);
    try {
      final rep = await WebsiteSync(s.biz, cfg.connector()).run(cfg);
      if (_session == s) state = state.copyWith(busy: false, last: rep, error: null);
    } catch (e) {
      if (_session == s) state = state.copyWith(busy: false, error: '$e');
      if (!quiet) rethrow;
    } finally {
      _running = false;
    }
  }
}

final websiteProvider = NotifierProvider<WebsiteController, WebsiteStatus>(WebsiteController.new);
