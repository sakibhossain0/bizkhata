import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../data/business_store.dart';
import 'remote_store.dart';
import 'sync_engine.dart';

/// A device that has opened a business, as recorded in the cloud.
class CloudDevice {
  final String id;
  final String name;
  final String tag;
  final DateTime? seen;
  const CloudDevice(this.id, this.name, this.tag, this.seen);
}

/// A business kept in the cloud folder.
class CloudBusiness {
  final String id;
  final String name;
  final String type;
  final DateTime? updated;
  final List<CloudDevice> devices;
  const CloudBusiness(this.id, this.name, this.type, this.updated, this.devices);
}

/// `bk_<business>_meta.json`: name, the newest full copy, and the devices.
class CloudMeta {
  final String id;
  String name;
  String type;
  Map<String, dynamic> snapshot;
  final Map<String, Map<String, dynamic>> devices;
  CloudMeta({required this.id, required this.name, required this.type, required this.snapshot, required this.devices});

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'type': type, 'snapshot': snapshot, 'devices': devices};
  factory CloudMeta.fromJson(Map<String, dynamic> j) => CloudMeta(
        id: j['id'] as String,
        name: j['name'] as String? ?? 'Business',
        type: j['type'] as String? ?? 'other',
        snapshot: Map<String, dynamic>.from(j['snapshot'] as Map? ?? const {}),
        devices: {
          for (final e in (j['devices'] as Map? ?? const {}).entries)
            '${e.key}': Map<String, dynamic>.from(e.value as Map),
        },
      );

  List<CloudDevice> get deviceList => [
        for (final e in devices.entries)
          CloudDevice(e.key, '${e.value['name'] ?? '?'}', '${e.value['tag'] ?? ''}', DateTime.tryParse('${e.value['seen']}')),
      ]..sort((a, b) => a.tag.compareTo(b.tag));
}

/// What a new device needs to make a downloaded copy its own.
class JoinInfo {
  final CloudMeta meta;
  final String fromDevice;
  final int fromPushed;
  final String tag;
  const JoinInfo(this.meta, this.fromDevice, this.fromPushed, this.tag);
}

class SyncReport {
  int pushed = 0;
  int pulled = 0;
  int images = 0;
  bool snapshot = false;
}

/// Device label shown in the device list ("Windows PC (SHOP-PC)", "Android phone").
String deviceLabel() {
  if (Platform.isAndroid) return 'Android phone';
  final host = Platform.localHostname;
  final kind = Platform.isWindows ? 'Windows PC' : (Platform.isMacOS ? 'Mac' : 'Computer');
  return host.isEmpty ? kind : '$kind ($host)';
}

/// Keeps businesses in a [RemoteStore] (the app's hidden Google Drive folder):
///
/// * `bk_<biz>_meta.json`           name, newest snapshot, devices
/// * `bk_<biz>_snap_<time>.db.gz`   a full copy, for devices that join later
/// * `bk_<biz>_chg_<dev>_<seq>.json.gz`  one device's batch of changes
/// * `bk_<biz>_img_<file>`          product photos and the logo
class CloudSync {
  final RemoteStore store;
  CloudSync(this.store);

  /// A fresh full copy is uploaded when the newest one is older than this.
  static const snapshotEvery = Duration(days: 7);

  /// A device's own change files older than this (and inside a newer snapshot) are removed.
  static const keepChanges = Duration(days: 45);

  static const _heartbeat = Duration(minutes: 15);

  Future<(RemoteFile, CloudMeta)?> _meta(String biz) async {
    final files = await store.list({'biz': biz, 'kind': 'meta'});
    if (files.isEmpty) return null;
    files.sort((a, b) => a.modified.compareTo(b.modified));
    final f = files.last;
    final m = CloudMeta.fromJson(Map<String, dynamic>.from(jsonDecode(utf8.decode(await store.read(f))) as Map));
    return (f, m);
  }

  Future<void> _saveMeta(CloudMeta m, RemoteFile? existing) => store.write(
        'bk_${m.id}_meta.json',
        utf8.encode(jsonEncode(m.toJson())),
        props: {'biz': m.id, 'kind': 'meta'},
        replace: existing,
      );

  Future<CloudMeta?> meta(String biz) async => (await _meta(biz))?.$2;

  /// Businesses kept in this Google account.
  Future<List<CloudBusiness>> businesses() async {
    final out = <CloudBusiness>[];
    for (final f in await store.list({'kind': 'meta'})) {
      try {
        final m = CloudMeta.fromJson(Map<String, dynamic>.from(jsonDecode(utf8.decode(await store.read(f))) as Map));
        out.add(CloudBusiness(m.id, m.name, m.type, f.modified, m.deviceList));
      } catch (_) {
        // A damaged meta file should not hide the other businesses.
      }
    }
    out.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return out;
  }

  /// Put a business online from this device (the first one).
  Future<void> upload({
    required BusinessInfo info,
    required SyncEngine engine,
    required String deviceName,
    required String tempDir,
  }) async {
    if (await _meta(info.id) != null) throw SyncException('already_in_cloud');
    await engine.startAsFirstDevice();
    final dev = await engine.deviceId();
    final snap = await _uploadSnapshot(info.id, engine, tempDir);
    final now = DateTime.now().toUtc().toIso8601String();
    await _saveMeta(
      CloudMeta(id: info.id, name: info.name, type: info.type, snapshot: snap, devices: {
        dev: {'name': deviceName, 'tag': 'A', 'seen': now},
      }),
      null,
    );
    await _uploadImages(info.id, engine, _localImageNames(engine));
  }

  Future<Map<String, dynamic>> _uploadSnapshot(String biz, SyncEngine engine, String tempDir) async {
    final vector = await engine.appliedVector();
    final dev = await engine.deviceId();
    final at = DateTime.now().toUtc();
    final tmp = await engine.exportCopy(p.join(tempDir, 'bk-snap-$biz-${at.millisecondsSinceEpoch}.db'));
    final bytes = gzip.encode(await tmp.readAsBytes());
    try {
      tmp.deleteSync();
    } catch (_) {}
    final name = 'bk_${biz}_snap_${at.millisecondsSinceEpoch}.db.gz';
    final f = await store.write(name, bytes, props: {'biz': biz, 'kind': 'snap', 'by': dev});
    return {'file': f.id, 'name': name, 'vector': vector, 'at': at.toIso8601String(), 'by': dev};
  }

  /// Download a business's newest full copy to [dbPath] for a device that joins.
  Future<JoinInfo> downloadSnapshot(String biz, String dbPath) async {
    final hit = await _meta(biz);
    if (hit == null) throw SyncException('not_in_cloud');
    final meta = hit.$2;
    final snaps = await store.list({'biz': biz, 'kind': 'snap'});
    if (snaps.isEmpty) throw SyncException('not_in_cloud');
    snaps.sort((a, b) => a.modified.compareTo(b.modified));
    final want = snaps.where((s) => s.id == meta.snapshot['file']).firstOrNull ?? snaps.last;
    final bytes = gzip.decode(await store.read(want));
    final file = File(dbPath);
    file.parent.createSync(recursive: true);
    for (final suffix in ['-wal', '-shm', '-journal']) {
      final side = File('$dbPath$suffix');
      if (side.existsSync()) side.deleteSync();
    }
    file.writeAsBytesSync(bytes, flush: true);
    final vector = Map<String, dynamic>.from(meta.snapshot['vector'] as Map? ?? const {});
    final by = '${meta.snapshot['by']}';
    final used = meta.devices.values.map((d) => '${d['tag']}').toSet();
    return JoinInfo(meta, by, (vector[by] as num?)?.toInt() ?? 0, _nextTag(used));
  }

  /// B, C, ... Z, AA, AB ... — the first device is A (no letter on its invoices).
  static String _nextTag(Set<String> used) {
    String tagFor(int n) {
      var s = '';
      for (var i = n; i >= 0; i = i ~/ 26 - 1) {
        s = String.fromCharCode(65 + i % 26) + s;
      }
      return s;
    }

    for (var n = 1;; n++) {
      final t = tagFor(n);
      if (!used.contains(t)) return t;
    }
  }

  /// Record this device in the business's device list.
  Future<void> registerDevice(String biz, SyncEngine engine, String deviceName) async {
    final hit = await _meta(biz);
    if (hit == null) throw SyncException('not_in_cloud');
    final tag = await engine.deviceTag();
    hit.$2.devices[await engine.deviceId()] = {
      'name': deviceName,
      'tag': tag.isEmpty ? 'A' : tag,
      'seen': DateTime.now().toUtc().toIso8601String(),
    };
    await _saveMeta(hit.$2, hit.$1);
    await engine.set('seen_at', DateTime.now().toUtc().toIso8601String());
  }

  /// Upload this device's changes, then apply everyone else's.
  Future<SyncReport> sync({
    required String biz,
    required SyncEngine engine,
    required String deviceName,
    required String tempDir,
    String? businessName,
  }) async {
    final rep = SyncReport();
    final me = await engine.deviceId();

    // 1. push
    final cs = await engine.buildChangeset();
    if (cs != null) {
      rep.images += await _uploadImages(biz, engine, cs.imageNames);
      await store.write(
        'bk_${biz}_chg_${me}_${cs.toSeq.toString().padLeft(14, '0')}.json.gz',
        cs.encode(),
        props: {'biz': biz, 'kind': 'chg', 'dev': me, 'from': '${cs.fromSeq}', 'to': '${cs.toSeq}'},
      );
      await engine.markPushed(cs);
      rep.pushed = cs.changes.length;
    }

    // 2. pull
    final pulledAt = DateTime.tryParse(await engine.get('pulled_at') ?? '');
    final files = await store.list(
      {'biz': biz, 'kind': 'chg'},
      // A small overlap guards against clock rounding; repeats are skipped by sequence number.
      modifiedAfter: pulledAt?.subtract(const Duration(minutes: 5)),
    );
    var newest = pulledAt;
    final byDevice = <String, List<RemoteFile>>{};
    for (final f in files) {
      if (newest == null || f.modified.isAfter(newest)) newest = f.modified;
      final dev = f.props['dev'];
      if (dev == null || dev == me) continue;
      byDevice.putIfAbsent(dev, () => []).add(f);
    }
    final missing = <String>{};
    for (final entry in byDevice.entries) {
      int seq(RemoteFile f, String k) => int.tryParse(f.props[k] ?? '') ?? 0;
      final list = entry.value..sort((a, b) => seq(a, 'to').compareTo(seq(b, 'to')));
      var done = await engine.appliedSeq(entry.key);
      for (final f in list) {
        if (seq(f, 'to') <= done) continue;
        // Older batches from this device were cleaned up: start again from a full copy.
        if (seq(f, 'from') > done + 1) throw SyncException('resync_needed');
        final res = await engine.apply(Changeset.decode(await store.read(f)));
        rep.pulled += res.applied;
        missing.addAll(res.missingImages);
        done = seq(f, 'to');
      }
    }
    if (newest != null) await engine.set('pulled_at', newest.toUtc().toIso8601String());

    // 3. photos referenced by what came in
    rep.images += await _downloadImages(biz, engine, missing);

    // 4. housekeeping
    await _maintain(biz, engine, deviceName, tempDir, rep, businessName);
    return rep;
  }

  /// Photos a device that just joined still needs.
  Future<int> fetchImages(String biz, SyncEngine engine, Set<String> names) => _downloadImages(biz, engine, names);

  Future<void> _maintain(
      String biz, SyncEngine engine, String deviceName, String tempDir, SyncReport rep, String? businessName) async {
    final seen = DateTime.tryParse(await engine.get('seen_at') ?? '');
    final now = DateTime.now().toUtc();
    if (seen != null && now.difference(seen) < _heartbeat) return;
    final hit = await _meta(biz);
    if (hit == null) return;
    final meta = hit.$2;
    final me = await engine.deviceId();
    final tag = await engine.deviceTag();
    meta.devices[me] = {'name': deviceName, 'tag': tag.isEmpty ? 'A' : tag, 'seen': now.toIso8601String()};
    if (businessName != null && businessName.trim().isNotEmpty) meta.name = businessName.trim();
    final snapAt = DateTime.tryParse('${meta.snapshot['at']}');
    if (snapAt == null || now.difference(snapAt) > snapshotEvery) {
      meta.snapshot = await _uploadSnapshot(biz, engine, tempDir);
      rep.snapshot = true;
      await _tidy(biz, engine, meta);
    }
    await _saveMeta(meta, hit.$1);
    await engine.set('seen_at', now.toIso8601String());
  }

  /// Remove old full copies and this device's old change files that a newer full copy already contains.
  Future<void> _tidy(String biz, SyncEngine engine, CloudMeta meta) async {
    final snaps = await store.list({'biz': biz, 'kind': 'snap'})
      ..sort((a, b) => b.modified.compareTo(a.modified));
    for (final old in snaps.skip(3)) {
      await store.delete(old);
    }
    final me = await engine.deviceId();
    final covered = ((meta.snapshot['vector'] as Map?)?[me] as num?)?.toInt() ?? 0;
    final cutoff = DateTime.now().toUtc().subtract(keepChanges);
    for (final f in await store.list({'biz': biz, 'kind': 'chg', 'dev': me})) {
      final to = int.tryParse(f.props['to'] ?? '') ?? 0;
      if (to <= covered && f.modified.isBefore(cutoff)) await store.delete(f);
    }
  }

  // ---------------------------------------------------------------- photos

  Set<String> _localImageNames(SyncEngine engine) {
    final names = <String>{};
    final dir = engine.imagesDir == null ? null : Directory(engine.imagesDir!);
    if (dir != null && dir.existsSync()) {
      names.addAll(dir.listSync().whereType<File>().map((f) => p.basename(f.path)));
    }
    final biz = engine.bizDir == null ? null : Directory(engine.bizDir!);
    if (biz != null && biz.existsSync()) {
      names.addAll(biz.listSync().whereType<File>().map((f) => p.basename(f.path)).where((n) => n.startsWith('logo')));
    }
    return names;
  }

  String? _localPath(SyncEngine engine, String name) {
    final dir = name.startsWith('logo') ? engine.bizDir : engine.imagesDir;
    return dir == null ? null : p.join(dir, name);
  }

  Future<int> _uploadImages(String biz, SyncEngine engine, Set<String> names) async {
    var n = 0;
    for (final name in names) {
      final path = _localPath(engine, name);
      if (path == null) continue;
      final f = File(path);
      if (!f.existsSync()) continue;
      final stamp = '${f.lengthSync()}:${f.lastModifiedSync().millisecondsSinceEpoch}';
      if (await engine.get('img:$name') == stamp) continue;
      final existing = await store.list({'biz': biz, 'kind': 'img', 'file': name});
      await store.write('bk_${biz}_img_$name', await f.readAsBytes(),
          props: {'biz': biz, 'kind': 'img', 'file': name}, replace: existing.firstOrNull);
      await engine.set('img:$name', stamp);
      n++;
    }
    return n;
  }

  Future<int> _downloadImages(String biz, SyncEngine engine, Set<String> names) async {
    var n = 0;
    for (final name in names) {
      final path = _localPath(engine, name);
      if (path == null) continue;
      final hits = await store.list({'biz': biz, 'kind': 'img', 'file': name});
      if (hits.isEmpty) continue;
      final f = File(path);
      f.parent.createSync(recursive: true);
      await f.writeAsBytes(await store.read(hits.first), flush: true);
      await engine.set('img:$name', '${f.lengthSync()}:${f.lastModifiedSync().millisecondsSinceEpoch}');
      n++;
    }
    return n;
  }
}
