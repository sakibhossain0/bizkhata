import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:drift/drift.dart';
import 'package:path/path.dart' as p;

import '../data/database.dart';
import 'sync_schema.dart';

class SyncException implements Exception {
  /// update_app | resync_needed | not_in_cloud | not_signed_in | not_configured | network
  final String code;
  final String? detail;
  SyncException(this.code, [this.detail]);
  @override
  String toString() => detail == null ? code : '$code:$detail';
}

/// One row's latest state: [row] null means the row was deleted.
class Change {
  final String table;
  final String key;
  final int ts;
  final Map<String, Object?>? row;
  const Change(this.table, this.key, this.ts, this.row);
  bool get deleted => row == null;

  Map<String, Object?> toJson() => {'t': table, 'k': key, 'ts': ts, if (row != null) 'r': row};
  factory Change.fromJson(Map<String, dynamic> j) =>
      Change(j['t'] as String, j['k'] as String, (j['ts'] as num).toInt(), (j['r'] as Map?)?.cast<String, Object?>());
}

/// A batch of one device's changes, uploaded as one small file.
class Changeset {
  final int schema;
  final String device;

  /// Sequence numbers in the sending device's change log; consecutive
  /// changesets from one device have `from == previous.to + 1`.
  final int fromSeq;
  final int toSeq;
  final DateTime createdAt;
  final List<Change> changes;
  const Changeset({
    required this.schema,
    required this.device,
    required this.fromSeq,
    required this.toSeq,
    required this.createdAt,
    required this.changes,
  });

  Map<String, Object?> toJson() => {
        'schema': schema,
        'device': device,
        'from': fromSeq,
        'to': toSeq,
        'at': createdAt.toUtc().toIso8601String(),
        'changes': [for (final c in changes) c.toJson()],
      };

  factory Changeset.fromJson(Map<String, dynamic> j) => Changeset(
        schema: (j['schema'] as num).toInt(),
        device: j['device'] as String,
        fromSeq: (j['from'] as num).toInt(),
        toSeq: (j['to'] as num).toInt(),
        createdAt: DateTime.parse(j['at'] as String),
        changes: [for (final c in j['changes'] as List) Change.fromJson(Map<String, dynamic>.from(c as Map))],
      );

  List<int> encode() => gzip.encode(utf8.encode(jsonEncode(toJson())));
  static Changeset decode(List<int> bytes) =>
      Changeset.fromJson(Map<String, dynamic>.from(jsonDecode(utf8.decode(gzip.decode(bytes))) as Map));

  /// File names of product photos and the logo mentioned in this batch.
  Set<String> get imageNames => {
        for (final c in changes)
          if (c.row != null && c.table == 'products' && c.row!['image_path'] is String)
            fileNameOf(c.row!['image_path'] as String)
          else if (c.row != null && c.table == 'settings' && c.row!['key'] == 'logo_path' && c.row!['value'] is String)
            fileNameOf(c.row!['value'] as String),
      }..remove('');
}

/// The last part of a path written on any system (`C:\x\p_1.jpg` or `/data/x/p_1.jpg`).
String fileNameOf(String path) => path.split(RegExp(r'[\\/]')).last;

class ApplyResult {
  int applied = 0;
  int skipped = 0;

  /// Photos referenced by applied rows that are not on this device yet.
  final missingImages = <String>{};
}

/// Row-level sync of one business database: collects this device's changes
/// and applies other devices' changes, newest write winning per row.
///
/// Stock is the exception to "last write wins": a product's stock column is
/// never copied from another device; every stock movement is synced as its
/// own `stock_moves` row and added here, so sales made on two devices at the
/// same time both come off the stock.
class SyncEngine {
  final AppDatabase db;

  /// Where product photos and the logo live on this device (null: leave paths alone).
  final String? imagesDir;
  final String? bizDir;
  SyncEngine(this.db, {this.imagesDir, this.bizDir});

  Future<String?> get(String k) async =>
      (await db.customSelect('SELECT v FROM sync_state WHERE k = ?', variables: [Variable.withString(k)]).getSingleOrNull())
          ?.read<String?>('v');

  Future<void> set(String k, String? v) async {
    if (v == null) {
      await db.customStatement('DELETE FROM sync_state WHERE k = ?', [k]);
    } else {
      await db.customStatement('INSERT INTO sync_state (k, v) VALUES (?, ?) ON CONFLICT(k) DO UPDATE SET v = excluded.v', [k, v]);
    }
  }

  Future<bool> get isOn async => await get('on') == '1';

  /// A stable random id for this device and business.
  Future<String> deviceId() async {
    var id = await get('device');
    if (id == null) {
      id = _hex(8);
      await set('device', id);
    }
    return id;
  }

  /// Letter added to this device's invoice numbers ('' on the first device).
  Future<String> deviceTag() async => await get('tag') ?? '';

  static String _hex(int bytes) {
    final r = Random.secure();
    return List.generate(bytes, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
  }

  /// A random id block for a device joining a business (never block 0).
  static int randomIdBase() => (Random.secure().nextInt(9000000) + 1) * AppDatabase.idBlock;

  /// The device that first puts a business online keeps id block 0 and its numbering.
  Future<void> startAsFirstDevice() async {
    await deviceId();
    await set('tag', '');
    await set('pushed', '0');
    await set('on', '1');
  }

  /// Paused devices keep recording changes (so nothing is lost) but don't upload them.
  Future<bool> get isPaused async => await get('paused') == '1';
  Future<void> setPaused(bool paused) => set('paused', paused ? '1' : null);

  /// Make a database that was just downloaded from Google Drive this device's
  /// own: new device id and id block (unless re-adopting after a resync), no
  /// leftover change log from the device that made the snapshot.
  Future<void> adoptSnapshot({
    required String fromDevice,
    required int fromPushed,
    required String tag,
    String? keepDeviceId,
    int? keepIdBase,
    int keepPushed = 0,
  }) async {
    final base = keepIdBase ?? randomIdBase();
    await db.transaction(() async {
      await db.customStatement('DELETE FROM sync_log');
      final me = keepDeviceId ?? _hex(8);
      await set('device', me);
      await set('id_base', '$base');
      await set('tag', tag);
      // A device starting again from a fresh copy keeps counting its changes
      // where it left off, or the others would skip its next batches as old.
      await set('pushed', '$keepPushed');
      await db.customStatement("DELETE FROM sqlite_sequence WHERE name = 'sync_log'");
      await db.customStatement("INSERT INTO sqlite_sequence (name, seq) VALUES ('sync_log', ?)", [keepPushed]);
      await set('applying', null);
      await set('pulled_at', null);
      await set('on', '1');
      await db.customStatement('DELETE FROM sync_applied WHERE dev = ?', [me]);
      if (fromDevice != me) {
        await db.customStatement(
            'INSERT INTO sync_applied (dev, seq) VALUES (?, ?) ON CONFLICT(dev) DO UPDATE SET seq = MAX(seq, excluded.seq)',
            [fromDevice, fromPushed]);
      }
    });
    db.idBase = base;
    db.resetIdCache();
  }

  Future<int> pendingCount() async =>
      (await db.customSelect('SELECT COUNT(*) AS n FROM sync_log').getSingle()).read<int>('n');

  /// Re-counts whenever a synced table changes.
  Stream<int> watchPending() => db
      .customSelect('SELECT COUNT(*) AS n FROM sync_log', readsFrom: db.allTables.toSet())
      .watchSingle()
      .map((r) => r.read<int>('n'));

  Future<int> appliedSeq(String device) async =>
      (await db.customSelect('SELECT seq FROM sync_applied WHERE dev = ?', variables: [Variable.withString(device)])
              .getSingleOrNull())
          ?.read<int>('seq') ??
      0;

  /// What other devices' changes this database already contains.
  Future<Map<String, int>> appliedVector() async {
    final rows = await db.customSelect('SELECT dev, seq FROM sync_applied').get();
    final v = {for (final r in rows) r.read<String>('dev'): r.read<int>('seq')};
    v[await deviceId()] = int.tryParse(await get('pushed') ?? '') ?? 0;
    return v;
  }

  // ------------------------------------------------------------------ push

  Future<Map<String, Object?>?> _readRow(String table, String key) async {
    final col = syncKeyColumn(table);
    final r = await db.customSelect('SELECT * FROM "$table" WHERE "$col" = ?',
        variables: [syncKeyIsInt(table) ? Variable.withInt(int.parse(key)) : Variable.withString(key)]).getSingleOrNull();
    return r?.data.cast<String, Object?>();
  }

  /// This device's changes since the last push, one entry per row (latest state).
  Future<Changeset?> buildChangeset() async {
    final dev = await deviceId();
    final pushed = int.tryParse(await get('pushed') ?? '') ?? 0;
    final groups = await db.customSelect(
      'SELECT tbl, pk, MAX(ts) AS ts, MAX(seq) AS seq FROM sync_log WHERE seq > ? GROUP BY tbl, pk ORDER BY MAX(seq)',
      variables: [Variable.withInt(pushed)],
    ).get();
    if (groups.isEmpty) return null;
    final changes = <Change>[];
    var toSeq = pushed;
    for (final g in groups) {
      final t = g.read<String>('tbl');
      final k = g.read<String>('pk');
      toSeq = max(toSeq, g.read<int>('seq'));
      changes.add(Change(t, k, g.read<int>('ts'), await _readRow(t, k)));
    }
    return Changeset(
      schema: db.schemaVersion,
      device: dev,
      fromSeq: pushed + 1,
      toSeq: toSeq,
      createdAt: DateTime.now().toUtc(),
      changes: changes,
    );
  }

  /// After [cs] reached Google Drive: remember when each row changed and drop the log entries.
  Future<void> markPushed(Changeset cs) => db.transaction(() async {
        for (final c in cs.changes) {
          await _setMeta(c, cs.device);
        }
        await db.customStatement('DELETE FROM sync_log WHERE seq <= ?', [cs.toSeq]);
        await set('pushed', '${cs.toSeq}');
      });

  Future<void> _setMeta(Change c, String dev) => db.customStatement(
        'INSERT INTO sync_meta (tbl, pk, ts, dev, del) VALUES (?, ?, ?, ?, ?) '
        'ON CONFLICT(tbl, pk) DO UPDATE SET ts = excluded.ts, dev = excluded.dev, del = excluded.del',
        [c.table, c.key, c.ts, dev, c.deleted ? 1 : 0],
      );

  // ----------------------------------------------------------------- apply

  final _columnCache = <String, Set<String>>{};
  Future<Set<String>> _columns(String table) async => _columnCache[table] ??=
      (await db.customSelect('PRAGMA table_info("$table")').get()).map((r) => r.read<String>('name')).toSet();

  /// Does the incoming change beat what this device has for the row?
  Future<bool> _remoteWins(Change c, String remoteDev, String me) async {
    final meta = await db.customSelect('SELECT ts, dev FROM sync_meta WHERE tbl = ? AND pk = ?',
        variables: [Variable.withString(c.table), Variable.withString(c.key)]).getSingleOrNull();
    final pending = (await db.customSelect('SELECT MAX(ts) AS ts FROM sync_log WHERE tbl = ? AND pk = ?',
            variables: [Variable.withString(c.table), Variable.withString(c.key)]).getSingle())
        .readNullable<int>('ts');
    int? localTs = meta?.read<int>('ts');
    String? localDev = meta?.read<String>('dev');
    if (pending != null && (localTs == null || pending >= localTs)) {
      localTs = pending;
      localDev = me;
    }
    if (localTs == null) return true;
    if (c.ts != localTs) return c.ts > localTs;
    return remoteDev.compareTo(localDev!) > 0;
  }

  /// Apply another device's changeset. Safe to call twice: already-applied
  /// batches and rows are skipped.
  Future<ApplyResult> apply(Changeset cs) async {
    final res = ApplyResult();
    final me = await deviceId();
    if (cs.device == me) return res;
    if (cs.schema > db.schemaVersion) throw SyncException('update_app');
    if (cs.toSeq <= await appliedSeq(cs.device)) {
      res.skipped = cs.changes.length;
      return res;
    }
    final order = {for (var i = 0; i < syncTables.length; i++) syncTables[i]: i};
    final known = cs.changes.where((c) => order.containsKey(c.table));
    final upserts = known.where((c) => !c.deleted).toList()..sort((a, b) => order[a.table]!.compareTo(order[b.table]!));
    final deletes = known.where((c) => c.deleted).toList()..sort((a, b) => order[b.table]!.compareTo(order[a.table]!));
    final touched = <String>{};
    await db.transaction(() async {
      await set('applying', '1');
      await db.customStatement('PRAGMA defer_foreign_keys = ON');
      var hlc = int.tryParse(await get('hlc') ?? '') ?? 0;
      for (final c in [...upserts, ...deletes]) {
        if (c.table == 'settings' && localOnlySettings.contains(c.key)) {
          res.skipped++;
          continue;
        }
        if (!await _remoteWins(c, cs.device, me)) {
          res.skipped++;
          continue;
        }
        if (c.deleted) {
          await _delete(c);
        } else {
          await _upsert(c, cs.device, res);
        }
        await _setMeta(c, cs.device);
        touched.add(c.table);
        hlc = max(hlc, c.ts);
        res.applied++;
      }
      await set('hlc', '$hlc');
      await db.customStatement(
          'INSERT INTO sync_applied (dev, seq) VALUES (?, ?) ON CONFLICT(dev) DO UPDATE SET seq = excluded.seq',
          [cs.device, cs.toSeq]);
      await set('applying', null);
    });
    if (touched.isNotEmpty) {
      db.markTablesUpdated(db.allTables.where((t) => touched.contains(t.actualTableName)));
    }
    return res;
  }

  Object _keyValue(Change c) => syncKeyIsInt(c.table) ? int.parse(c.key) : c.key;

  Future<void> _delete(Change c) async {
    final col = syncKeyColumn(c.table);
    if (c.table == 'stock_moves') {
      final m = await db.customSelect('SELECT product_id, qty FROM stock_moves WHERE id = ?',
          variables: [Variable.withInt(int.parse(c.key))]).getSingleOrNull();
      if (m != null) {
        await db.customStatement('UPDATE products SET stock = ROUND(stock - ?, 3) WHERE id = ?',
            [m.read<double>('qty'), m.read<int>('product_id')]);
      }
    }
    await db.customStatement('DELETE FROM "${c.table}" WHERE "$col" = ?', [_keyValue(c)]);
  }

  Future<void> _upsert(Change c, String remoteDev, ApplyResult res) async {
    final t = c.table;
    final col = syncKeyColumn(t);
    final cols = await _columns(t);
    final row = <String, Object?>{
      for (final e in c.row!.entries)
        if (cols.contains(e.key)) e.key: e.value,
    };
    final existed = await db.customSelect('SELECT 1 FROM "$t" WHERE "$col" = ?',
            variables: [syncKeyIsInt(t) ? Variable.withInt(int.parse(c.key)) : Variable.withString(c.key)]).getSingleOrNull() !=
        null;
    if (t == 'products') {
      // Stock arrives as stock_moves; keep ours (or start from zero for a new product).
      if (existed) {
        row.remove('stock');
      } else {
        row['stock'] = 0.0;
      }
      _relinkImage(row, 'image_path', imagesDir, res);
    }
    if (t == 'settings' && row['key'] == 'logo_path') _relinkImage(row, 'value', bizDir, res);

    Future<void> write() async {
      final names = row.keys.toList();
      final updates = names.where((n) => n != col).map((n) => '"$n" = excluded."$n"').join(', ');
      await db.customStatement(
        'INSERT INTO "$t" (${names.map((n) => '"$n"').join(', ')}) VALUES (${List.filled(names.length, '?').join(', ')}) '
        'ON CONFLICT("$col") DO ${updates.isEmpty ? 'NOTHING' : 'UPDATE SET $updates'}',
        [for (final n in names) row[n]],
      );
    }

    try {
      await write();
    } catch (e) {
      if (!e.toString().contains('UNIQUE constraint failed')) rethrow;
      if (t == 'categories' || t == 'expense_categories') {
        // Both devices made a category with the same name: keep both, tell them apart.
        row['name'] = '${row['name']} (${remoteDev.substring(0, 4)})';
        await write();
      } else if (t != 'ext_links') {
        rethrow;
      }
      // ext_links: this device already linked that website record; keep ours.
    }

    if (t == 'stock_moves' && !existed) {
      await db.customStatement('UPDATE products SET stock = ROUND(stock + ?, 3) WHERE id = ?', [row['qty'], row['product_id']]);
    }
  }

  /// Point a photo path at this device's folder; note it if the file isn't here yet.
  void _relinkImage(Map<String, Object?> row, String column, String? dir, ApplyResult res) {
    final v = row[column];
    if (dir == null || v is! String || v.isEmpty) return;
    final name = fileNameOf(v);
    final local = p.join(dir, name);
    row[column] = local;
    if (!File(local).existsSync()) res.missingImages.add(name);
  }

  /// After opening a snapshot made on another device: rewrite photo paths to
  /// this device's folders. Returns the photos that still need downloading.
  Future<Set<String>> relinkAllImages() async {
    final missing = <String>{};
    if (imagesDir == null) return missing;
    await db.transaction(() async {
      await set('applying', '1');
      final rows = await db.customSelect('SELECT id, image_path FROM products WHERE image_path IS NOT NULL').get();
      for (final r in rows) {
        final name = fileNameOf(r.read<String>('image_path'));
        if (name.isEmpty) continue;
        final local = p.join(imagesDir!, name);
        if (!File(local).existsSync()) missing.add(name);
        await db.customStatement('UPDATE products SET image_path = ? WHERE id = ?', [local, r.read<int>('id')]);
      }
      final logo = await db.customSelect("SELECT value FROM settings WHERE key = 'logo_path'").getSingleOrNull();
      final lv = logo?.read<String>('value') ?? '';
      if (bizDir != null && lv.isNotEmpty) {
        final name = fileNameOf(lv);
        final local = p.join(bizDir!, name);
        if (!File(local).existsSync()) missing.add(name);
        await db.customStatement("UPDATE settings SET value = ? WHERE key = 'logo_path'", [local]);
      }
      await set('applying', null);
    });
    db.markTablesUpdated([db.products, db.settings]);
    return missing;
  }

  /// A consistent copy of the whole database (for the Google Drive snapshot).
  Future<File> exportCopy(String path) async {
    final f = File(path);
    if (f.existsSync()) f.deleteSync();
    f.parent.createSync(recursive: true);
    await db.customStatement("VACUUM INTO '${path.replaceAll("'", "''")}'");
    return f;
  }
}
