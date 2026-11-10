import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/business_store.dart';
import '../sync/cloud_sync.dart';
import '../sync/drive_store.dart';
import '../sync/google_auth.dart';
import '../sync/sync_engine.dart';
import 'app_state.dart';

final googleAuthProvider = Provider<GoogleAuth>((ref) => GoogleAuth.forPlatform());

/// How the app reaches the cloud folder (tests swap in a memory store).
final cloudProvider = Provider<CloudSync>((ref) => CloudSync(DriveStore(ref.read(googleAuthProvider).accessToken)));

class GoogleUserController extends Notifier<GoogleUser?> {
  @override
  GoogleUser? build() {
    Future.microtask(() async {
      try {
        final u = await ref.read(googleAuthProvider).restore();
        if (u != null) state = u;
      } catch (_) {
        // Offline or not configured: stay signed out.
      }
    });
    return null;
  }

  Future<GoogleUser> signIn() async => state = await ref.read(googleAuthProvider).signIn();

  Future<void> signOut() async {
    await ref.read(googleAuthProvider).signOut();
    state = null;
  }
}

final googleUserProvider = NotifierProvider<GoogleUserController, GoogleUser?>(GoogleUserController.new);

class CloudStatus {
  /// Sync is set up for the open business.
  final bool on;
  final bool paused;
  final bool busy;
  final DateTime? lastSync;

  /// A [SyncException] code (or `network`) from the last attempt.
  final String? error;
  final int pending;
  const CloudStatus({this.on = false, this.paused = false, this.busy = false, this.lastSync, this.error, this.pending = 0});

  CloudStatus copyWith({bool? on, bool? paused, bool? busy, DateTime? lastSync, Object? error = _keep, int? pending}) =>
      CloudStatus(
        on: on ?? this.on,
        paused: paused ?? this.paused,
        busy: busy ?? this.busy,
        lastSync: lastSync ?? this.lastSync,
        error: identical(error, _keep) ? this.error : error as String?,
        pending: pending ?? this.pending,
      );
  static const _keep = Object();
}

/// Keeps the open business in step with Google Drive: on open, every minute,
/// shortly after each change, and when the app goes to the background.
class CloudSyncController extends Notifier<CloudStatus> with WidgetsBindingObserver {
  Session? _session;
  SyncEngine? _engine;
  Timer? _timer;
  Timer? _soon;
  StreamSubscription<int>? _pending;
  bool _running = false;

  @override
  CloudStatus build() {
    WidgetsBinding.instance.addObserver(this);
    ref.onDispose(() {
      WidgetsBinding.instance.removeObserver(this);
      _detach();
    });
    ref.listen(appProvider, (_, phase) => _onPhase(phase), fireImmediately: true);
    ref.listen(googleUserProvider, (before, user) {
      if (before == null && user != null) syncNow(quiet: true);
    });
    return const CloudStatus();
  }

  Session? _sessionOf(AppPhase phase) => switch (phase) {
        Ready(:final session) => session,
        Locked(:final session) => session,
        _ => null,
      };

  void _onPhase(AppPhase phase) {
    final s = _sessionOf(phase);
    if (s?.biz.db == _session?.biz.db) {
      _session = s; // same database, maybe another person logged in
      return;
    }
    _detach();
    if (s != null) _attach(s);
  }

  Future<void> _attach(Session s) async {
    _session = s;
    String? images;
    String? folder;
    try {
      images = (await BusinessStore.imagesDir(s.info.id)).path;
      folder = (await BusinessStore.folder(s.info.id)).path;
    } catch (_) {
      // No file system here (tests): sync rows, leave photos alone.
    }
    final engine = SyncEngine(s.biz.db, imagesDir: images, bizDir: folder);
    if (_session != s) return;
    _engine = engine;
    state = CloudStatus(
      on: await engine.isOn,
      paused: await engine.isPaused,
      lastSync: DateTime.tryParse(await engine.get('last_sync') ?? ''),
      pending: await engine.pendingCount(),
    );
    _pending = engine.watchPending().listen((n) {
      state = state.copyWith(pending: n);
      if (n > 0) _syncSoon();
    });
    _timer = Timer.periodic(const Duration(minutes: 1), (_) => syncNow(quiet: true));
    if (state.on) unawaited(syncNow(quiet: true));
  }

  void _detach() {
    _timer?.cancel();
    _soon?.cancel();
    _pending?.cancel();
    _timer = _soon = null;
    _pending = null;
    _engine = null;
    _session = null;
  }

  void _syncSoon() {
    _soon?.cancel();
    _soon = Timer(const Duration(seconds: 15), () => syncNow(quiet: true));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Leaving the app: upload what's waiting while we still can.
    if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden) unawaited(syncNow(quiet: true));
  }

  String get _tmp => Directory.systemTemp.path;

  /// Upload and download now. With [quiet], errors only show in the status.
  Future<void> syncNow({bool quiet = false}) async {
    final s = _session;
    final e = _engine;
    if (s == null || e == null || _running) return;
    if (!await e.isOn || await e.isPaused) return;
    if (ref.read(googleAuthProvider).user == null) {
      state = state.copyWith(error: 'not_signed_in');
      if (!quiet) throw SyncException('not_signed_in');
      return;
    }
    _running = true;
    state = state.copyWith(busy: true);
    try {
      await ref.read(cloudProvider).sync(
            biz: s.info.id,
            engine: e,
            deviceName: deviceLabel(),
            tempDir: _tmp,
            businessName: s.info.name,
          );
      final now = DateTime.now();
      if (_engine == e) {
        await e.set('last_sync', now.toIso8601String());
        state = state.copyWith(busy: false, lastSync: now, error: null);
      }
    } on SyncException catch (x) {
      if (_engine != e) return;
      if (x.code == 'resync_needed') {
        state = state.copyWith(busy: false);
        _running = false;
        await ref.read(appProvider.notifier).refreshFromCloud(ref.read(cloudProvider));
        return;
      }
      state = state.copyWith(busy: false, error: x.code);
      if (!quiet) rethrow;
    } catch (x) {
      if (_engine != e) return; // business closed mid-sync
      state = state.copyWith(busy: false, error: 'network');
      if (!quiet) rethrow;
    } finally {
      _running = false;
    }
  }

  /// Put the open business in Google Drive (signing in first if needed).
  Future<void> enable() async {
    final s = _session;
    final e = _engine;
    if (s == null || e == null) return;
    if (ref.read(googleAuthProvider).user == null) await ref.read(googleUserProvider.notifier).signIn();
    final cloud = ref.read(cloudProvider);
    await cloud.upload(info: s.info, engine: e, deviceName: deviceLabel(), tempDir: _tmp);
    await e.set('last_sync', DateTime.now().toIso8601String());
    state = state.copyWith(on: true, paused: false, lastSync: DateTime.now(), error: null);
  }

  Future<void> setPaused(bool paused) async {
    await _engine?.setPaused(paused);
    state = state.copyWith(paused: paused);
    if (!paused) await syncNow();
  }

  /// Devices that have opened this business.
  Future<List<CloudDevice>> devices() async {
    final s = _session;
    if (s == null) return const [];
    return (await ref.read(cloudProvider).meta(s.info.id))?.deviceList ?? const [];
  }

  Future<String> deviceId() async => await _engine?.deviceId() ?? '';
}

final cloudSyncProvider = NotifierProvider<CloudSyncController, CloudStatus>(CloudSyncController.new);
