import 'dart:convert';
import 'dart:io';

import 'package:bizkhata/sync/drive_store.dart';
import 'package:bizkhata/sync/google_auth.dart';
import 'package:bizkhata/sync/remote_store.dart';
import 'package:bizkhata/sync/sync_engine.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class MemoryVault extends TokenVault {
  Map<String, dynamic>? data;
  @override
  Future<Map<String, dynamic>?> read() async => data;
  @override
  Future<void> write(Map<String, dynamic> d) async => data = d;
  @override
  Future<void> clear() async => data = null;
}

void main() {
  group('Google Drive store', () {
    test('lists the hidden app folder by tags, following pages', () async {
      final seen = <Uri>[];
      final store = DriveStore(({bool refresh = false}) async => 'tok', client: MockClient((req) async {
        seen.add(req.url);
        expect(req.headers['Authorization'], 'Bearer tok');
        final page = req.url.queryParameters['pageToken'];
        return http.Response(
            jsonEncode({
              if (page == null) 'nextPageToken': 'p2',
              'files': [
                {'id': page == null ? 'a' : 'b', 'name': 'x', 'modifiedTime': '2026-11-10T10:00:00.000Z', 'appProperties': {'biz': 'b1'}},
              ],
            }),
            200);
      }));
      final files = await store.list({'biz': 'b1', 'kind': 'chg'}, modifiedAfter: DateTime.utc(2026, 11, 10));
      expect(files.map((f) => f.id), ['a', 'b']);
      final q = seen.first.queryParameters['q']!;
      expect(seen.first.queryParameters['spaces'], 'appDataFolder');
      expect(q, contains("appProperties has { key='biz' and value='b1' }"));
      expect(q, contains("appProperties has { key='kind' and value='chg' }"));
      expect(q, contains("modifiedTime > '2026-11-10T00:00:00.000Z'"));
    });

    test('uploads into the app folder with tags, as one multipart request', () async {
      late http.Request sent;
      final store = DriveStore(({bool refresh = false}) async => 'tok', client: MockClient((req) async {
        sent = req;
        return http.Response(jsonEncode({'id': 'new', 'name': 'f', 'modifiedTime': '2026-11-10T10:00:00Z'}), 200);
      }));
      final f = await store.write('bk_b1_meta.json', utf8.encode('{"a":1}'), props: {'biz': 'b1', 'kind': 'meta'});
      expect(f.id, 'new');
      expect(sent.method, 'POST');
      expect(sent.url.queryParameters['uploadType'], 'multipart');
      expect(sent.headers['content-type'], startsWith('multipart/related; boundary='));
      final body = utf8.decode(sent.bodyBytes);
      expect(body, contains('"parents":["appDataFolder"]'));
      expect(body, contains('"appProperties":{"biz":"b1","kind":"meta"}'));
      expect(body, contains('{"a":1}'));
    });

    test('a rejected token is refreshed once, then the request is retried', () async {
      var calls = 0;
      final refreshes = <bool>[];
      final store = DriveStore(({bool refresh = false}) async {
        refreshes.add(refresh);
        return refresh ? 'fresh' : 'stale';
      }, client: MockClient((req) async {
        calls++;
        if (req.headers['Authorization'] == 'Bearer stale') return http.Response('{"error":"invalid"}', 401);
        return http.Response('hello', 200);
      }));
      final bytes = await store.read(RemoteFile('f1', 'x', DateTime.now(), const {}));
      expect(utf8.decode(bytes), 'hello');
      expect(calls, 2);
      expect(refreshes, [false, true]);
    });
  });

  group('Windows sign-in (browser + 127.0.0.1)', () {
    test('signs in with PKCE, keeps the refresh token, and refreshes later', () async {
      final vault = MemoryVault();
      String? verifierSent;
      final client = MockClient((req) async {
        if (req.url.host == 'oauth2.googleapis.com' && req.url.path == '/token') {
          final form = req.bodyFields;
          if (form['grant_type'] == 'authorization_code') {
            expect(form['code'], 'good-code');
            verifierSent = form['code_verifier'];
            return http.Response(jsonEncode({'access_token': 'a1', 'expires_in': 3600, 'refresh_token': 'r1'}), 200);
          }
          expect(form['refresh_token'], 'r1');
          return http.Response(jsonEncode({'access_token': 'a2', 'expires_in': 3600}), 200);
        }
        if (req.url.path == '/v1/userinfo') {
          return http.Response(jsonEncode({'email': 'owner@example.com', 'name': 'Shop Owner'}), 200);
        }
        return http.Response('', 404);
      });
      late Uri asked;
      final auth = DesktopGoogleAuth(
        clientId: 'cid',
        clientSecret: 'secret',
        client: client,
        vault: vault,
        // The "browser": Google sends the user back to the app with a code.
        openBrowser: (url) async {
          asked = url;
          final back = Uri.parse(url.queryParameters['redirect_uri']!)
              .replace(queryParameters: {'code': 'good-code', 'state': url.queryParameters['state']!});
          Future(() async {
            final r = await HttpClient().getUrl(back);
            await (await r.close()).drain<void>();
          });
          return true;
        },
      );
      final user = await auth.signIn();
      expect(user.email, 'owner@example.com');
      expect(asked.queryParameters['scope'], contains(driveScope));
      expect(asked.queryParameters['code_challenge_method'], 'S256');
      final challenge = base64UrlEncode(sha256.convert(ascii.encode(verifierSent!)).bytes).replaceAll('=', '');
      expect(asked.queryParameters['code_challenge'], challenge);
      expect(vault.data!['refresh'], 'r1');
      expect(await auth.accessToken(), 'a1');
      expect(await auth.accessToken(refresh: true), 'a2');
    });

    test('a revoked sign-in asks to sign in again and forgets the token', () async {
      final vault = MemoryVault()..data = {'refresh': 'gone', 'user': {'email': 'a@b.c'}};
      final auth = DesktopGoogleAuth(
        clientId: 'cid',
        clientSecret: 's',
        vault: vault,
        client: MockClient((req) async => http.Response(jsonEncode({'error': 'invalid_grant'}), 400)),
      );
      expect(await auth.restore(), isNull);
      expect(vault.data, isNull);
      expect(() => auth.accessToken(), throwsA(isA<SyncException>().having((e) => e.code, 'code', 'not_signed_in')));
    });
  });
}
