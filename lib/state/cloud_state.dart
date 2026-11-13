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
import 'auth_state.dart';

export 'auth_state.dart';

/// How the app reaches the cloud folder (tests swap in a memory store).
final cloudProvider = Provider<CloudSync>((ref) => CloudSync(DriveStore(ref.read(googleAuthProvider).accessToken)));

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

/// After a failed upload, automatic tries wait this long (a full copy of a
/// shop is big for a phone's data plan).
const autoUploadRetry = Duration(minutes: 5);

/// Whether a shop that isn't in Google Drive yet may be put there by itself:
/// the owner is using it, someone is signed in and has allowed Drive, the shop
/// is that account's (or older than accounts), and the last try was long enough ago.
bool mayAutoUpload({
  required bool byOwner,
  required String? shopOwner,
  required GoogleUser? user,
  required bool driveAllowed,
  DateTime? failedAt,
  DateTime? now,
}) {
  if (!byOwner || user == null || !driveAllowed) return false;
  final owner = normalizeOwner(shopOwner);
  if (owner != null && owner != normalizeOwner(user.email)) return false;
  return failedAt == null || (now ?? DateTime.now()).difference(failedAt) >= autoUploadRetry;
}

/// Keeps the open business in step with Google Drive: on open, every minute,
/// shortly after each change, and when the app goes to the background. A shop
/// that isn't in Drive yet goes there by itself (see [mayAutoUpload]), so it
/// shows up on the account's other devices.
class CloudSyncController extends Notifier<CloudStatus> with WidgetsBindingObserver {
  Session? _session;
  SyncEngine? _engine;
  Timer? _timer;
  Timer? _soon;
  StreamSubscription<int>? _pending;

  /// A sync or an upload is under way; never two at once.
  bool _running = false;

  /// When the open shop's last upload failed.
  DateTime? _uploadFailedAt;

  /// Drive already has a copy of the open shop that this device didn't make:
  /// no more automatic tries until the shop is opened again.
  bool _uploadRefused = false;

  /// Set in the shop's sync state (to this device's id) while its first
  /// upload is under way. [CloudSync.upload] turns syncing on before the copy
  /// is in Drive, so a try that broke off is finished by the next one instead
  /// of leaving a shop that syncs while no other device can find it.
  static const _firstUpload = 'first_upload';

  @override
  CloudStatus build() {
    WidgetsBinding.instance.addObserver(this);
    ref.onDispose(() {
      WidgetsBinding.instance.removeObserver(this);
      _detach();
    });
    ref.listen(appProvider, (_, phase) => _onPhase(phase), fireImmediately: true);
    ref.listen(googleUserProvider, (before, user) {
      if (before == null && user != null) unawaited(_keepUp());
    });
    // Drive was just allowed: try now, not at the next minute or after the
    // pause that follows a failed upload. A "not allowed" error is old news.
    ref.listen(driveAccessProvider, (before, allowed) {
      if (!allowed || before != false) return;
      _uploadFailedAt = null;
      if (state.error == 'no_drive') state = state.copyWith(error: null);
      unawaited(_keepUp());
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
      // Just unlocked: if it was the owner, the shop may go to Drive now.
      if (phase is Ready) unawaited(_keepUp());
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
    _uploadFailedAt = null;
    _uploadRefused = false;
    final status = CloudStatus(
      on: await engine.isOn && !await _unfinished(engine),
      paused: await engine.isPaused,
      lastSync: DateTime.tryParse(await engine.get('last_sync') ?? ''),
      pending: await engine.pendingCount(),
    );
    if (_engine != engine) return; // closed or switched meanwhile: no timers for it
    state = status;
    _pending = engine.watchPending().listen((n) {
      state = state.copyWith(pending: n);
      if (n > 0) _syncSoon();
    });
    _timer = Timer.periodic(const Duration(minutes: 1), (_) => _keepUp());
    unawaited(_keepUp());
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

  /// This device began the shop's first upload, and Drive may not have it yet.
  Future<bool> _unfinished(SyncEngine e) async {
    final mark = await e.get(_firstUpload);
    return mark != null && mark == await e.deviceId();
  }

  bool get _failedLately => _uploadFailedAt != null && DateTime.now().difference(_uploadFailedAt!) < autoUploadRetry;

  /// Sync the open shop, or put it in Drive when it isn't there yet.
  Future<void> _keepUp() async {
    final e = _engine;
    if (e == null || _running) return;
    try {
      if (await e.isOn) {
        await syncNow(quiet: true);
      } else {
        await _autoUpload();
      }
    } catch (_) {
      // The shop was closed meanwhile; other failures are kept in [state].
    }
  }

  void _failed(String code) {
    state = state.copyWith(busy: false, error: code);
    // Drive refused the token: bring back the "Allow Google Drive" banner.
    if (code == 'no_drive') ref.read(driveAccessProvider.notifier).recheck();
  }

  /// Upload and download now. With [quiet], errors only show in the status.
  Future<void> syncNow({bool quiet = false}) async {
    final s = _session;
    final e = _engine;
    if (s == null || e == null || _running) return;
    // Taken before the first await, so two calls can't both get past here.
    _running = true;
    var resync = false;
    try {
      if (!await e.isOn || await e.isPaused) return;
      if (ref.read(googleAuthProvider).user == null) throw SyncException('not_signed_in');
      // A first upload that broke off is finished before anything syncs into
      // a shop the other devices can't see yet.
      final unfinished = await _unfinished(e);
      if (unfinished && quiet && _failedLately) return;
      state = state.copyWith(busy: true);
      if (unfinished) {
        await _upload(s, e);
      } else {
        await ref.read(cloudProvider).sync(
              biz: s.info.id,
              engine: e,
              deviceName: deviceLabel(),
              tempDir: _tmp,
              businessName: s.info.name,
            );
      }
      final now = DateTime.now();
      if (_engine == e) {
        await e.set('last_sync', now.toIso8601String());
        state = state.copyWith(on: true, busy: false, lastSync: now, error: null);
      }
    } on SyncException catch (x) {
      if (_engine == e) {
        if (x.code == 'resync_needed') {
          resync = true;
          state = state.copyWith(busy: false);
        } else {
          _failed(x.code);
          if (!quiet) rethrow;
        }
      }
    } catch (x) {
      if (_engine == e) {
        // (Otherwise the business was closed mid-sync.)
        _failed('network');
        if (!quiet) rethrow;
      }
    } finally {
      _running = false;
    }
    // Away too long: start again from the newest full copy (after letting go
    // of [_running], so the reopened shop can sync straight away).
    if (resync) await ref.read(appProvider.notifier).refreshFromCloud(ref.read(cloudProvider));
  }

  /// Put the open shop in Google Drive by itself, when [mayAutoUpload] says so.
  /// A shop already in Drive, even paused there, is left as it is.
  Future<void> _autoUpload() async {
    final s = _session;
    final e = _engine;
    if (s == null || e == null || _running || _uploadRefused) return;
    final auth = ref.read(googleAuthProvider);
    final may = mayAutoUpload(
      // While locked at start-up the session's owner is only a stand-in:
      // nobody has entered a PIN yet.
      byOwner: s.actor.isOwner && ref.read(appProvider) is Ready,
      shopOwner: s.info.owner,
      user: auth.user,
      driveAllowed: auth.driveAllowed,
      failedAt: _uploadFailedAt,
    );
    if (!may) return;
    _running = true;
    try {
      if (await e.isOn) return;
      state = state.copyWith(busy: true);
      await _upload(s, e);
      if (_engine == e) state = state.copyWith(on: true, paused: false, busy: false, lastSync: DateTime.now(), error: null);
    } on SyncException catch (x) {
      if (_engine == e) _failed(x.code);
    } catch (_) {
      if (_engine == e) _failed('network');
    } finally {
      _running = false;
    }
  }

  /// Put the open shop in Google Drive as its first device, or finish such an
  /// upload that broke off (see [_firstUpload]).
  Future<void> _upload(Session s, SyncEngine e) async {
    final again = await _unfinished(e);
    await e.set(_firstUpload, await e.deviceId());
    final cloud = ref.read(cloudProvider);
    try {
      try {
        await cloud.upload(info: s.info, engine: e, deviceName: deviceLabel(), tempDir: _tmp);
      } on SyncException catch (x) {
        // A copy from the earlier try is ours: that try got it into Drive
        // before it broke off, and syncing has been on since.
        if (x.code != 'already_in_cloud' || !again) rethrow;
        // Its photos went up last, so some may be missing (sent ones are
        // skipped). If this fails too, the next try carries on from here.
        await cloud.uploadMissingImages(s.info.id, e);
      }
    } catch (x) {
      final code = x is SyncException ? x.code : null;
      // Refused before anything was sent: allowing Drive, or signing in,
      // starts the next try without the usual wait.
      if (code != 'no_drive' && code != 'not_signed_in') _uploadFailedAt = DateTime.now();
      // Someone else's copy: trying again won't change that.
      if (code == 'already_in_cloud') _uploadRefused = true;
      try {
        // Failed before it began (syncing still off): nothing to finish later.
        if (!await e.isOn) await e.set(_firstUpload, null);
      } catch (_) {}
      rethrow;
    }
    await e.set(_firstUpload, null);
    await e.set('last_sync', DateTime.now().toIso8601String());
    _uploadFailedAt = null;
  }

  /// Put the open business in Google Drive (signing in first if needed).
  Future<void> enable() async {
    final s = _session;
    final e = _engine;
    if (s == null || e == null) return;
    if (ref.read(googleAuthProvider).user == null) await ref.read(googleUserProvider.notifier).signIn();
    // An automatic upload or a sync may be under way: let it finish first.
    while (_running) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    if (_engine != e) return;
    _running = true;
    try {
      // The automatic upload may have done it meanwhile.
      if (!await e.isOn || await _unfinished(e)) {
        state = state.copyWith(busy: true);
        await _upload(s, e);
      }
      final last = DateTime.tryParse(await e.get('last_sync') ?? '');
      final paused = await e.isPaused;
      if (_engine == e) state = state.copyWith(on: true, paused: paused, busy: false, lastSync: last, error: null);
    } catch (x) {
      if (_engine == e) _failed(x is SyncException ? x.code : 'network');
      rethrow;
    } finally {
      _running = false;
    }
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
    final access = ref.read(driveAccessProvider.notifier);
    try {
      return (await ref.read(cloudProvider).meta(s.info.id))?.deviceList ?? const [];
    } on SyncException catch (x) {
      if (x.code == 'no_drive') access.recheck();
      rethrow;
    }
  }

  Future<String> deviceId() async => await _engine?.deviceId() ?? '';
}

final cloudSyncProvider = NotifierProvider<CloudSyncController, CloudStatus>(CloudSyncController.new);
