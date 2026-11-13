import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'remote_store.dart';
import 'sync_engine.dart';

/// The app's hidden folder in the user's own Google Drive (`appDataFolder`).
/// Only BizKhata can see these files; they count towards the user's Drive storage.
class DriveStore implements RemoteStore {
  /// A valid access token; `refresh: true` asks for a new one after a 401.
  final Future<String> Function({bool refresh}) token;
  final http.Client _http;
  DriveStore(this.token, {http.Client? client}) : _http = client ?? http.Client();

  static const _files = 'https://www.googleapis.com/drive/v3/files';
  static const _upload = 'https://www.googleapis.com/upload/drive/v3/files';
  static const _fields = 'id,name,modifiedTime,appProperties';

  /// Above this, uploads use Drive's resumable protocol instead of one request.
  static const _resumableAbove = 4 * 1024 * 1024;

  Future<http.Response> _send(String method, Uri url, {Map<String, String>? headers, Object? body}) async {
    for (var attempt = 0;; attempt++) {
      final req = http.Request(method, url)..headers['Authorization'] = 'Bearer ${await token(refresh: attempt == 1)}';
      if (headers != null) req.headers.addAll(headers);
      if (body is List<int>) req.bodyBytes = body;
      if (body is String) req.body = body;
      final http.Response res;
      try {
        res = await http.Response.fromStream(await _http.send(req)).timeout(const Duration(seconds: 90));
      } on TimeoutException {
        throw SyncException('network', 'Google Drive did not answer');
      } catch (e) {
        if (e is SyncException) rethrow;
        throw SyncException('network', '$e');
      }
      // A token without the Drive permission gets one more try with a fresh
      // token, which also lets the sign-in see that Drive isn't allowed.
      final noDrive = res.statusCode == 403 && _lacksDrive(res.body);
      if ((res.statusCode == 401 || noDrive) && attempt == 0) continue;
      final busy = res.statusCode == 429 ||
          res.statusCode >= 500 ||
          (res.statusCode == 403 && res.body.contains('ateLimitExceeded'));
      if (busy && attempt < 4) {
        await Future<void>.delayed(Duration(milliseconds: 500 * (1 << attempt)));
        continue;
      }
      if (res.statusCode == 401) throw SyncException('not_signed_in');
      if (noDrive) throw SyncException('no_drive');
      if (res.statusCode >= 400) {
        final text = res.body.length > 300 ? res.body.substring(0, 300) : res.body;
        throw SyncException('drive', '${res.statusCode} $text');
      }
      return res;
    }
  }

  /// Drive's answer to a token that doesn't carry its permission (Google's
  /// consent page lets people untick Drive and still sign in).
  static bool _lacksDrive(String body) {
    final b = body.toLowerCase();
    return b.contains('insufficientpermissions') ||
        b.contains('insufficient authentication scopes') ||
        b.contains('access_token_scope_insufficient');
  }

  static String _quote(String v) => v.replaceAll(r'\', r'\\').replaceAll("'", r"\'");

  static RemoteFile _file(Map<String, dynamic> j) => RemoteFile(
        j['id'] as String,
        j['name'] as String? ?? '',
        DateTime.tryParse('${j['modifiedTime']}')?.toUtc() ?? DateTime.now().toUtc(),
        {for (final e in (j['appProperties'] as Map? ?? const {}).entries) '${e.key}': '${e.value}'},
      );

  @override
  Future<List<RemoteFile>> list(Map<String, String> props, {DateTime? modifiedAfter}) async {
    final q = [
      'trashed = false',
      for (final e in props.entries) "appProperties has { key='${_quote(e.key)}' and value='${_quote(e.value)}' }",
      if (modifiedAfter != null) "modifiedTime > '${modifiedAfter.toUtc().toIso8601String()}'",
    ].join(' and ');
    final out = <RemoteFile>[];
    String? page;
    do {
      final url = Uri.parse(_files).replace(queryParameters: {
        'spaces': 'appDataFolder',
        'q': q,
        'fields': 'nextPageToken,files($_fields)',
        'pageSize': '1000',
        'orderBy': 'modifiedTime',
        'pageToken': ?page,
      });
      final j = jsonDecode((await _send('GET', url)).body) as Map<String, dynamic>;
      out.addAll([for (final f in j['files'] as List? ?? const []) _file(Map<String, dynamic>.from(f as Map))]);
      page = j['nextPageToken'] as String?;
    } while (page != null);
    return out;
  }

  @override
  Future<Uint8List> read(RemoteFile file) async =>
      (await _send('GET', Uri.parse('$_files/${file.id}?alt=media'))).bodyBytes;

  @override
  Future<RemoteFile> write(String name, List<int> bytes, {Map<String, String> props = const {}, RemoteFile? replace}) async {
    final meta = jsonEncode({
      'name': name,
      if (replace == null) 'parents': ['appDataFolder'],
      if (props.isNotEmpty) 'appProperties': props,
    });
    final method = replace == null ? 'POST' : 'PATCH';
    final target = replace == null ? _upload : '$_upload/${replace.id}';
    if (bytes.length > _resumableAbove) {
      final start = await _send(method, Uri.parse('$target?uploadType=resumable&fields=$_fields'), headers: {
        'Content-Type': 'application/json; charset=UTF-8',
        'X-Upload-Content-Type': 'application/octet-stream',
        'X-Upload-Content-Length': '${bytes.length}',
      }, body: meta);
      final session = start.headers['location'];
      if (session == null) throw SyncException('drive', 'no upload session');
      final done = await _send('PUT', Uri.parse(session), headers: {'Content-Type': 'application/octet-stream'}, body: bytes);
      return _file(jsonDecode(done.body) as Map<String, dynamic>);
    }
    final boundary = 'bizkhata${DateTime.now().microsecondsSinceEpoch}';
    final body = BytesBuilder(copy: false)
      ..add(utf8.encode('--$boundary\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n$meta\r\n'
          '--$boundary\r\nContent-Type: application/octet-stream\r\n\r\n'))
      ..add(bytes)
      ..add(utf8.encode('\r\n--$boundary--'));
    final res = await _send(method, Uri.parse('$target?uploadType=multipart&fields=$_fields'),
        headers: {'Content-Type': 'multipart/related; boundary=$boundary'}, body: body.takeBytes());
    return _file(jsonDecode(res.body) as Map<String, dynamic>);
  }

  @override
  Future<void> delete(RemoteFile file) async {
    try {
      await _send('DELETE', Uri.parse('$_files/${file.id}'));
    } on SyncException catch (e) {
      if (!(e.detail ?? '').startsWith('404')) rethrow; // already gone
    }
  }
}
