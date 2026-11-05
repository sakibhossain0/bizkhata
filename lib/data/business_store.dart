import 'dart:convert';
import 'dart:io';

import 'package:drift_flutter/drift_flutter.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/sqlite3.dart' show Database, OpenMode, sqlite3;

import 'database.dart';

class BusinessInfo {
  final String id;
  final String name;
  final String type;
  final DateTime createdAt;
  const BusinessInfo({required this.id, required this.name, required this.type, required this.createdAt});

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'type': type, 'createdAt': createdAt.toIso8601String()};

  factory BusinessInfo.fromJson(Map<String, dynamic> j) => BusinessInfo(
        id: j['id'] as String,
        name: j['name'] as String? ?? 'Business',
        type: j['type'] as String? ?? 'other',
        createdAt: DateTime.tryParse('${j['createdAt']}') ?? DateTime.now(),
      );

  BusinessInfo copyWith({String? name, String? type}) =>
      BusinessInfo(id: id, name: name ?? this.name, type: type ?? this.type, createdAt: createdAt);
}

/// A deleted business kept for [BusinessStore.trashDays] days so it can be restored.
class DeletedBusiness {
  final String id;
  final String name;
  final String type;
  final DateTime deletedAt;
  const DeletedBusiness(this.id, this.name, this.type, this.deletedAt);
}

/// Each business is its own SQLite file under the app's support folder:
///   `<base>/businesses/<id>/bizkhata.sqlite` (+ `images/`, logo)
/// Deleted businesses move to `<base>/deleted/<id>/` with a `meta.json`.
/// The list of businesses and the open one live in shared preferences.
class BusinessStore {
  static const _listKey = 'businesses';
  static const _currentKey = 'current_business';
  static const _pendingKey = 'pending_trash';
  static const trashDays = 30;

  /// Set from `BIZKHATA_DATA_DIR` (and by tests) to keep data elsewhere.
  static String? overrideRoot;

  static Future<Directory> _base() async {
    if (overrideRoot != null) return Directory(overrideRoot!);
    return getApplicationSupportDirectory();
  }

  static Future<Directory> root() async {
    final dir = Directory(p.join((await _base()).path, 'businesses'));
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  static Future<Directory> _trash() async {
    final dir = Directory(p.join((await _base()).path, 'deleted'));
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  static Future<Directory> folder(String id) async {
    final dir = Directory(p.join((await root()).path, id));
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  static Future<String> dbPath(String id) async => p.join((await folder(id)).path, 'bizkhata.sqlite');

  static Future<Directory> imagesDir(String id) async {
    final dir = Directory(p.join((await folder(id)).path, 'images'));
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  static Future<List<BusinessInfo>> list() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_listKey);
    if (raw == null) return [];
    try {
      return (jsonDecode(raw) as List).map((e) => BusinessInfo.fromJson(Map<String, dynamic>.from(e as Map))).toList();
    } catch (_) {
      return [];
    }
  }

  static Future<void> _save(List<BusinessInfo> list) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_listKey, jsonEncode(list.map((b) => b.toJson()).toList()));
  }

  static Future<String?> currentId() async => (await SharedPreferences.getInstance()).getString(_currentKey);

  static Future<void> setCurrent(String id) async => (await SharedPreferences.getInstance()).setString(_currentKey, id);

  static Future<BusinessInfo> add(String name, String type) async {
    final info = BusinessInfo(
      id: 'b${DateTime.now().millisecondsSinceEpoch}',
      name: name.trim(),
      type: type,
      createdAt: DateTime.now(),
    );
    await _save([...await list(), info]);
    return info;
  }

  static Future<void> update(BusinessInfo info) async {
    final all = await list();
    await _save([for (final b in all) b.id == info.id ? info : b]);
  }

  /// Takes the business off the list and moves its folder to the trash.
  ///
  /// Windows can keep a just-closed database file locked for a moment (or an
  /// antivirus scan can), so the move is retried, and anything still locked is
  /// finished at the next start instead of failing — which used to leave the
  /// app stuck and the folder orphaned.
  static Future<void> remove(String id) async {
    final all = await list();
    final info = all.where((b) => b.id == id).firstOrNull;
    await _save(all.where((b) => b.id != id).toList());
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getString(_currentKey) == id) await prefs.remove(_currentKey);
    if (!await _moveToTrash(id, name: info?.name, type: info?.type)) {
      final pending = {...prefs.getStringList(_pendingKey) ?? const <String>[], id};
      await prefs.setStringList(_pendingKey, pending.toList());
    }
  }

  static Future<bool> _moveToTrash(String id, {String? name, String? type, int attempts = 8}) async {
    final src = Directory(p.join((await root()).path, id));
    if (!src.existsSync()) return true;
    final meta = {
      'id': id,
      'name': name ?? _readName(p.join(src.path, 'bizkhata.sqlite')) ?? 'Business',
      'type': type ?? 'other',
      'deletedAt': DateTime.now().toIso8601String(),
    };
    final dest = Directory(p.join((await _trash()).path, id));
    for (var i = 0; i < attempts; i++) {
      try {
        if (dest.existsSync()) dest.deleteSync(recursive: true);
        src.renameSync(dest.path);
        File(p.join(dest.path, 'meta.json')).writeAsStringSync(jsonEncode(meta));
        return true;
      } catch (_) {
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
    }
    return false;
  }

  /// Business name stored inside a database file (read-only peek).
  static String? _readName(String dbFile) {
    if (!File(dbFile).existsSync()) return null;
    Database? db;
    try {
      db = sqlite3.open(dbFile, mode: OpenMode.readOnly);
      final rows = db.select("SELECT value FROM settings WHERE key = 'business_name'");
      return rows.isEmpty ? null : rows.first['value'] as String?;
    } catch (_) {
      return null;
    } finally {
      db?.close();
    }
  }

  /// Run once at start-up, before any database is opened:
  ///  - finish deletions that were blocked by a locked file,
  ///  - move folders that are no longer on the list into the trash,
  ///  - permanently remove trash older than [trashDays] days.
  static Future<void> housekeeping() async {
    final prefs = await SharedPreferences.getInstance();
    final pending = prefs.getStringList(_pendingKey) ?? const <String>[];
    final stillPending = <String>[];
    for (final id in pending) {
      if (!await _moveToTrash(id, attempts: 2)) stillPending.add(id);
    }
    await prefs.setStringList(_pendingKey, stillPending);

    final known = {for (final b in await list()) b.id};
    for (final dir in (await root()).listSync().whereType<Directory>()) {
      final id = p.basename(dir.path);
      if (known.contains(id) || stillPending.contains(id)) continue;
      await _moveToTrash(id, attempts: 2);
    }

    for (final d in await deletedBusinesses()) {
      if (DateTime.now().difference(d.deletedAt).inDays > trashDays) await purgeDeleted(d.id);
    }
  }

  static Future<List<DeletedBusiness>> deletedBusinesses() async {
    final out = <DeletedBusiness>[];
    for (final dir in (await _trash()).listSync().whereType<Directory>()) {
      final id = p.basename(dir.path);
      var name = 'Business', type = 'other';
      var at = dir.statSync().modified;
      try {
        final m = jsonDecode(File(p.join(dir.path, 'meta.json')).readAsStringSync()) as Map;
        name = '${m['name'] ?? name}';
        type = '${m['type'] ?? type}';
        at = DateTime.tryParse('${m['deletedAt']}') ?? at;
      } catch (_) {
        name = _readName(p.join(dir.path, 'bizkhata.sqlite')) ?? name;
      }
      out.add(DeletedBusiness(id, name, type, at));
    }
    out.sort((a, b) => b.deletedAt.compareTo(a.deletedAt));
    return out;
  }

  /// Bring a deleted business back onto the list.
  static Future<BusinessInfo> restoreDeleted(String id) async {
    final src = Directory(p.join((await _trash()).path, id));
    final deleted = (await deletedBusinesses()).firstWhere((d) => d.id == id);
    final dest = Directory(p.join((await root()).path, id));
    if (dest.existsSync()) throw StateError('A business with this id already exists');
    src.renameSync(dest.path);
    final meta = File(p.join(dest.path, 'meta.json'));
    if (meta.existsSync()) meta.deleteSync();
    final info = BusinessInfo(id: id, name: deleted.name, type: deleted.type, createdAt: DateTime.now());
    await _save([...await list(), info]);
    return info;
  }

  static Future<void> purgeDeleted(String id) async {
    final dir = Directory(p.join((await _trash()).path, id));
    try {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    } catch (_) {}
  }

  static Future<AppDatabase> open(String id) async {
    final path = await dbPath(id);
    return AppDatabase(driftDatabase(
      name: 'bizkhata',
      native: DriftNativeOptions(databasePath: () async => path),
    ));
  }

  // ---------------- backups ----------------

  static Future<Directory> defaultBackupDir() async {
    final docs = await getApplicationDocumentsDirectory();
    return Directory(p.join(docs.path, 'BizKhata Backups'));
  }

  static String _safe(String s) => s.replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '_').trim();

  /// Consistent snapshot of a live database via `VACUUM INTO`.
  static Future<File> backupTo(AppDatabase db, String targetPath) async {
    final f = File(targetPath);
    if (f.existsSync()) f.deleteSync();
    f.parent.createSync(recursive: true);
    final escaped = targetPath.replaceAll("'", "''");
    await db.customStatement("VACUUM INTO '$escaped'");
    return f;
  }

  /// Daily automatic backup into `[dir]/<business>/`, keeping the newest [keep].
  static Future<File?> autoBackup(AppDatabase db, BusinessInfo info, {String? dir, int keep = 15}) async {
    final base = dir == null || dir.isEmpty ? await defaultBackupDir() : Directory(dir);
    final folder = Directory(p.join(base.path, '${_safe(info.name)} (${info.id})'));
    folder.createSync(recursive: true);
    final now = DateTime.now();
    final stamp = '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    final file = File(p.join(folder.path, 'auto-$stamp.bizkhata'));
    if (file.existsSync()) return null; // already backed up today
    await backupTo(db, file.path);
    final autos = folder.listSync().whereType<File>().where((f) => p.basename(f.path).startsWith('auto-')).toList()
      ..sort((a, b) => b.path.compareTo(a.path));
    for (final old in autos.skip(keep)) {
      try {
        old.deleteSync();
      } catch (_) {}
    }
    return file;
  }

  /// Check that a file really is a BizKhata database before restoring it.
  static Future<bool> looksValid(String path) async {
    final f = File(path);
    if (!f.existsSync() || f.lengthSync() < 1024) return false;
    final head = await f.openRead(0, 16).first;
    if (String.fromCharCodes(head.take(15)) != 'SQLite format 3') return false;
    // Read-only raw connection: opening through AppDatabase would run
    // migrations and could write into the user's file.
    Database? probe;
    try {
      probe = sqlite3.open(path, mode: OpenMode.readOnly);
      final rows = probe.select(
          "SELECT name FROM sqlite_master WHERE type='table' AND name IN ('sales','products','ledger_entries')");
      return rows.length == 3;
    } catch (_) {
      return false;
    } finally {
      probe?.close();
    }
  }

  /// Replace a business's database with [sourcePath]. The caller must have
  /// closed the open connection first.
  static Future<void> restoreFile(String id, String sourcePath) async {
    final target = await dbPath(id);
    // Keep the current file in case the restore needs undoing.
    final current = File(target);
    if (current.existsSync()) {
      current.copySync('$target.before-restore');
    }
    for (final suffix in ['-wal', '-shm', '-journal']) {
      final side = File('$target$suffix');
      if (side.existsSync()) side.deleteSync();
    }
    File(sourcePath).copySync(target);
  }
}
