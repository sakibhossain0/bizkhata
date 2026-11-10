import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../core/i18n.dart';
import '../core/util.dart';
import '../data/biz.dart';
import '../data/business_store.dart';
import '../data/seed.dart';
import '../sync/cloud_sync.dart';
import '../sync/sync_engine.dart';

class Session {
  final BusinessInfo info;
  final Biz biz;

  /// Who unlocked the app. Everyone is the owner until staff are added.
  final Actor actor;
  const Session(this.info, this.biz, [this.actor = Actor.owner]);
}

sealed class AppPhase {
  const AppPhase();
}

class Booting extends AppPhase {
  const Booting();
}

class Onboarding extends AppPhase {
  /// True when another business already exists (user can go back).
  final bool canCancel;
  const Onboarding({this.canCancel = false});
}

class Locked extends AppPhase {
  final Session session;
  const Locked(this.session);
}

class Ready extends AppPhase {
  final Session session;
  const Ready(this.session);
}

class BootError extends AppPhase {
  final String message;
  const BootError(this.message);
}

String hashPin(String salt, String pin) => sha256.convert(utf8.encode('bizkhata:$salt:$pin')).toString();

class AppController extends Notifier<AppPhase> {
  Session? _session;

  @override
  AppPhase build() {
    Future.microtask(_boot);
    return const Booting();
  }

  Session? get session => _session;

  Future<void> _boot() async {
    try {
      // Finish interrupted deletions and tidy orphaned folders first; a
      // failure here must never stop the app from opening.
      try {
        await BusinessStore.housekeeping();
      } catch (_) {}
      final list = await BusinessStore.list();
      if (list.isEmpty) {
        state = const Onboarding();
        return;
      }
      final current = await BusinessStore.currentId();
      final info = list.firstWhere((b) => b.id == current, orElse: () => list.first);
      await _open(info);
    } catch (e) {
      state = BootError('$e');
    }
  }

  Future<void> _open(BusinessInfo info, {bool lockIfPin = true, Actor? actor}) async {
    await _closeCurrent();
    final db = await BusinessStore.open(info.id);
    final biz = Biz(db);
    _session = Session(info, biz, actor ?? Actor.owner);
    db.actor = actor?.stamp;
    await BusinessStore.setCurrent(info.id);
    final pin = await biz.settings.get(K.pinHash);
    state = (actor == null && lockIfPin && pin != null && pin.isNotEmpty) ? Locked(_session!) : Ready(_session!);
    // Daily safety copy; never block the UI on it.
    Future(() async {
      try {
        final dir = await biz.settings.get(K.backupDir);
        final f = await BusinessStore.autoBackup(db, info, dir: dir);
        if (f != null) await biz.settings.set(K.lastBackupAt, DateTime.now().toIso8601String());
      } catch (_) {}
    });
  }

  Future<void> _closeCurrent() async {
    final s = _session;
    if (s == null) return;
    // Unmount the screens first so no live query runs against a closed db.
    state = const Booting();
    await Future<void>.delayed(const Duration(milliseconds: 80));
    _session = null;
    await s.biz.db.close();
  }

  Future<void> createBusiness({
    required String name,
    required String typeId,
    String phone = '',
    String address = '',
    bool demo = false,
  }) async {
    final info = await BusinessStore.add(name, typeId);
    final db = await BusinessStore.open(info.id);
    final biz = Biz(db);
    await seedBusiness(biz, name: name, typeId: typeId, phone: phone, address: address, bangla: isBangla);
    if (demo) await seedDemoData(biz, bangla: isBangla);
    await db.close();
    await _open(info, lockIfPin: false);
  }

  Future<void> switchTo(String id) async {
    final list = await BusinessStore.list();
    final info = list.firstWhere((b) => b.id == id);
    await _open(info);
  }

  void startAddBusiness() => state = const Onboarding(canCancel: true);

  void cancelAddBusiness() {
    if (_session != null) state = Ready(_session!);
  }

  /// Locks only when there is an owner PIN; otherwise there is nothing to unlock with.
  Future<void> lock() async {
    final s = _session;
    if (s == null) return;
    final pin = await s.biz.settings.get(K.pinHash);
    if (pin == null || pin.isEmpty) return;
    state = Locked(s);
  }

  /// Owner when [staffId] is null, otherwise that staff member.
  Future<bool> unlock(String pin, {int? staffId}) async {
    final s = _session;
    if (s == null) return false;
    Actor? actor;
    if (staffId == null) {
      final stored = await s.biz.settings.get(K.pinHash);
      if (stored == null || stored.isEmpty || stored == hashPin(s.info.id, pin)) actor = Actor.owner;
    } else {
      final u = await s.biz.staff.byId(staffId);
      if (u != null && u.active && checkStaffPin(u.pinHash, pin)) actor = Actor.staff(u);
    }
    if (actor == null) return false;
    _session = Session(s.info, s.biz, actor);
    s.biz.db.actor = actor.stamp;
    state = Ready(_session!);
    return true;
  }

  Future<void> setPin(String? pin) async {
    final s = _session;
    if (s == null) return;
    if (pin == null || pin.isEmpty) {
      // Without an owner PIN anyone could open the owner account past the staff.
      if ((await s.biz.staff.active()).isNotEmpty) throw BizException('staff_need_pin');
      await s.biz.settings.remove(K.pinHash);
    } else {
      await s.biz.settings.set(K.pinHash, hashPin(s.info.id, pin));
    }
  }

  Future<void> renameCurrent(String name, String type) async {
    final s = _session;
    if (s == null) return;
    final info = s.info.copyWith(name: name.trim(), type: type);
    await BusinessStore.update(info);
    _session = Session(info, s.biz, s.actor);
    state = Ready(_session!);
  }

  /// Swap the open database for a backup file.
  Future<void> restore(String path) async {
    final s = _session;
    if (s == null) return;
    await _closeCurrent();
    await BusinessStore.restoreFile(s.info.id, path);
    await _open(s.info, lockIfPin: false);
  }

  Future<void> deleteCurrent() async {
    final s = _session;
    if (s == null) return;
    await _closeCurrent();
    try {
      await BusinessStore.remove(s.info.id);
    } finally {
      // Always leave the splash screen, even if the folder could not be moved yet.
      await _boot();
    }
  }

  /// Open a business kept in Google Drive on this device for the first time:
  /// download its newest full copy, make it this device's own, catch up on
  /// changes since, then open it (asking for the PIN if it has one).
  Future<void> openFromCloud(CloudBusiness b, CloudSync cloud) async {
    if ((await BusinessStore.list()).any((x) => x.id == b.id)) return switchTo(b.id);
    final tmp = await Directory.systemTemp.createTemp('bk_join_');
    try {
      final download = p.join(tmp.path, 'bizkhata.sqlite');
      final join = await cloud.downloadSnapshot(b.id, download);
      final folder = await BusinessStore.folder(b.id);
      final images = await BusinessStore.imagesDir(b.id);
      File(download).copySync(await BusinessStore.dbPath(b.id));
      final db = await BusinessStore.open(b.id);
      try {
        final engine = SyncEngine(db, imagesDir: images.path, bizDir: folder.path);
        await engine.adoptSnapshot(fromDevice: join.fromDevice, fromPushed: join.fromPushed, tag: join.tag);
        await cloud.fetchImages(b.id, engine, await engine.relinkAllImages());
        await cloud.registerDevice(b.id, engine, deviceLabel());
        await cloud.sync(biz: b.id, engine: engine, deviceName: deviceLabel(), tempDir: tmp.path);
      } finally {
        await db.close();
      }
    } catch (_) {
      // Leave nothing half-made behind.
      try {
        (await BusinessStore.folder(b.id)).deleteSync(recursive: true);
      } catch (_) {}
      rethrow;
    } finally {
      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {}
    }
    final info = BusinessInfo(id: b.id, name: b.name, type: b.type, createdAt: DateTime.now());
    await BusinessStore.addExisting(info);
    await _open(info);
  }

  /// Start this business again from the newest full copy in Google Drive,
  /// after this device fell too far behind. Its own changes must already be
  /// uploaded; the person using the app stays logged in.
  Future<void> refreshFromCloud(CloudSync cloud) async {
    final s = _session;
    if (s == null) return;
    final old = SyncEngine(s.biz.db);
    if (await old.pendingCount() > 0) throw SyncException('pending');
    final device = await old.deviceId();
    final tag = await old.deviceTag();
    final base = s.biz.db.idBase;
    final pushed = int.tryParse(await old.get('pushed') ?? '') ?? 0;
    final tmp = await Directory.systemTemp.createTemp('bk_resync_');
    try {
      final download = p.join(tmp.path, 'bizkhata.sqlite');
      final join = await cloud.downloadSnapshot(s.info.id, download);
      await _closeCurrent();
      await BusinessStore.restoreFile(s.info.id, download);
      final db = await BusinessStore.open(s.info.id);
      try {
        final engine = SyncEngine(db,
            imagesDir: (await BusinessStore.imagesDir(s.info.id)).path, bizDir: (await BusinessStore.folder(s.info.id)).path);
        await engine.adoptSnapshot(
            fromDevice: join.fromDevice,
            fromPushed: join.fromPushed,
            tag: tag,
            keepDeviceId: device,
            keepIdBase: base,
            keepPushed: pushed);
        await cloud.fetchImages(s.info.id, engine, await engine.relinkAllImages());
        await cloud.sync(biz: s.info.id, engine: engine, deviceName: deviceLabel(), tempDir: tmp.path);
      } finally {
        await db.close();
      }
    } finally {
      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {}
    }
    await _open(s.info, actor: s.actor);
  }

  /// Bring back a business from "recently deleted" and open it.
  Future<void> restoreDeleted(String id) async {
    final info = await BusinessStore.restoreDeleted(id);
    await _open(info, lockIfPin: false);
  }
}

final appProvider = NotifierProvider<AppController, AppPhase>(AppController.new);

final sessionProvider = Provider<Session>((ref) {
  final phase = ref.watch(appProvider);
  if (phase is Ready) return phase.session;
  if (phase is Locked) return phase.session;
  throw StateError('No open business');
});

final bizProvider = Provider<Biz>((ref) => ref.watch(sessionProvider).biz);

final actorProvider = Provider<Actor>((ref) => ref.watch(sessionProvider).actor);

final settingsProvider = StreamProvider<Map<String, String>>((ref) => ref.watch(bizProvider).settings.watchAll());

final businessesProvider = FutureProvider<List<BusinessInfo>>((ref) {
  ref.watch(appProvider);
  return BusinessStore.list();
});

// ---------------- language ----------------

class LangController extends Notifier<Lang> {
  @override
  Lang build() => currentLang;

  Future<void> set(Lang lang) async {
    currentLang = lang;
    state = lang;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('lang', lang.name);
  }

  Future<void> toggle() => set(state == Lang.en ? Lang.bn : Lang.en);
}

final langProvider = NotifierProvider<LangController, Lang>(LangController.new);

Future<void> loadSavedLanguage() async {
  final prefs = await SharedPreferences.getInstance();
  final saved = prefs.getString('lang');
  currentLang = saved == 'en' ? Lang.en : (saved == 'bn' ? Lang.bn : Lang.bn);
}
