import 'dart:typed_data';

/// A file in the cloud folder. [props] are small searchable tags (business
/// id, kind, device ...) so listing never depends on file names.
class RemoteFile {
  final String id;
  final String name;
  final DateTime modified;
  final Map<String, String> props;
  const RemoteFile(this.id, this.name, this.modified, this.props);
}

/// Where synced businesses are kept. [DriveStore] is the real one (the app's
/// hidden folder in the user's Google Drive); [MemoryRemoteStore] is for tests.
abstract class RemoteStore {
  /// Files whose props include all of [props], optionally changed after [modifiedAfter].
  Future<List<RemoteFile>> list(Map<String, String> props, {DateTime? modifiedAfter});
  Future<Uint8List> read(RemoteFile file);

  /// Create a file, or replace the content of [replace].
  Future<RemoteFile> write(String name, List<int> bytes, {Map<String, String> props = const {}, RemoteFile? replace});
  Future<void> delete(RemoteFile file);
}

/// In-memory stand-in for Google Drive, shared by the "devices" in a test.
class MemoryRemoteStore implements RemoteStore {
  final _files = <String, (RemoteFile, Uint8List)>{};
  var _clock = DateTime.utc(2026, 1, 1);
  var _next = 0;
  int writes = 0;

  DateTime _tick() => _clock = _clock.add(const Duration(seconds: 1));

  @override
  Future<List<RemoteFile>> list(Map<String, String> props, {DateTime? modifiedAfter}) async => [
        for (final (f, _) in _files.values)
          if (props.entries.every((e) => f.props[e.key] == e.value) &&
              (modifiedAfter == null || f.modified.isAfter(modifiedAfter)))
            f,
      ]..sort((a, b) => a.name.compareTo(b.name));

  @override
  Future<Uint8List> read(RemoteFile file) async {
    final hit = _files[file.id];
    if (hit == null) throw StateError('not found: ${file.name}');
    return hit.$2;
  }

  @override
  Future<RemoteFile> write(String name, List<int> bytes, {Map<String, String> props = const {}, RemoteFile? replace}) async {
    writes++;
    final id = replace?.id ?? 'f${_next++}';
    final f = RemoteFile(id, name, _tick(), {...?_files[id]?.$1.props, ...props});
    _files[id] = (f, Uint8List.fromList(bytes));
    return f;
  }

  @override
  Future<void> delete(RemoteFile file) async => _files.remove(file.id);

  int get fileCount => _files.length;
}
