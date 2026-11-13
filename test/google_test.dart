import 'dart:async';
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

/// Google's side of the Windows sign-in. Each trip through the browser sends
/// back the next of [codes]; [tokens] answers a code, [refreshes] a refresh
/// token, and [emails] says whose each access token is.
class GoogleServer {
  final codes = <String>[];
  final tokens = <String, Map<String, dynamic>>{};
  final refreshes = <String, Map<String, dynamic>>{};
  final emails = <String, String>{};
  final asked = <Uri>[];

  /// Tabs still on Google's page: with no [codes] queued, a trip through the
  /// browser waits here until the test [finish]es it.
  final open = <Uri>[];

  /// Codes the app has handed back to Google for tokens.
  final exchanged = <String>[];

  /// Google's answer to these codes waits until the future completes.
  final slow = <String, Future<void>>{};

  late final client = MockClient((req) async {
    if (req.url.host == 'oauth2.googleapis.com' && req.url.path == '/token') {
      final form = req.bodyFields;
      final code = form['code'];
      if (form['grant_type'] == 'authorization_code') exchanged.add(code!);
      final wait = slow[code];
      if (wait != null) await wait;
      final answer = form['grant_type'] == 'authorization_code' ? tokens[code] : refreshes[form['refresh_token']];
      return answer == null
          ? http.Response(jsonEncode({'error': 'invalid_grant'}), 400)
          : http.Response(jsonEncode(answer), 200);
    }
    if (req.url.path == '/v1/userinfo') {
      final email = emails[req.headers['Authorization']?.replaceFirst('Bearer ', '')];
      return email == null ? http.Response('{}', 401) : http.Response(jsonEncode({'email': email}), 200);
    }
    return http.Response('', 404);
  });

  Future<bool> browser(Uri url) async {
    asked.add(url);
    if (codes.isEmpty) {
      open.add(url);
    } else {
      final code = codes.removeAt(0);
      Future(() => finish(url, code));
    }
    return true;
  }

  /// Google sends the tab back to the app with [code].
  Future<void> finish(Uri tab, String code) async {
    final back = Uri.parse(tab.queryParameters['redirect_uri']!)
        .replace(queryParameters: {'code': code, 'state': tab.queryParameters['state']!});
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    try {
      final r = await client.getUrl(back);
      await (await r.close()).drain<void>();
    } finally {
      client.close(force: true);
    }
  }

  /// The next tab left open on Google's page.
  Future<Uri> nextTab() async {
    for (var i = 0; i < 500 && open.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    return open.removeAt(0);
  }

  DesktopGoogleAuth auth(TokenVault vault) =>
      DesktopGoogleAuth(clientId: 'cid', clientSecret: 's', client: client, vault: vault, openBrowser: browser);
}

/// What Google grants when the Drive box is left unticked, and when it is ticked.
const _basic = 'openid https://www.googleapis.com/auth/userinfo.email https://www.googleapis.com/auth/userinfo.profile';
const _withDrive = '$_basic $driveScope';

Matcher _fails(String code) => throwsA(isA<SyncException>().having((e) => e.code, 'code', code));

Future<void> _until(bool Function() ok) async {
  for (var i = 0; i < 500 && !ok(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
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

    test('a token without the Drive permission is "Drive not allowed", not a raw error', () async {
      final refreshes = <bool>[];
      // What the owner's PC got after unticking Google Drive on the consent page.
      final store = DriveStore(({bool refresh = false}) async {
        refreshes.add(refresh);
        return 'tok';
      }, client: MockClient((req) async => http.Response(
          jsonEncode({
            'error': {
              'code': 403,
              'message': 'Request had insufficient authentication scopes.',
              'errors': [
                {'message': 'Insufficient Permission', 'domain': 'global', 'reason': 'insufficientPermissions'},
              ],
              'status': 'PERMISSION_DENIED',
              'details': [
                {'@type': 'type.googleapis.com/google.rpc.ErrorInfo', 'reason': 'ACCESS_TOKEN_SCOPE_INSUFFICIENT'},
              ],
            },
          }),
          403)));
      await expectLater(store.list({'kind': 'meta'}), _fails('no_drive'));
      expect(refreshes, [false, true], reason: 'one more try with a fresh token, which tells the sign-in too');
    });

    test('other refusals still say what Drive answered', () async {
      final store = DriveStore(({bool refresh = false}) async => 'tok',
          client: MockClient((req) async => http.Response('{"error":{"code":404,"message":"File not found"}}', 404)));
      await expectLater(
          store.read(RemoteFile('f1', 'x', DateTime.now(), const {})),
          throwsA(isA<SyncException>()
              .having((e) => e.code, 'code', 'drive')
              .having((e) => e.detail, 'detail', startsWith('404'))));
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

  group('Google Drive permission on Windows', () {
    // Google's consent page lets people untick Google Drive and still sign in.
    late GoogleServer google;
    late MemoryVault vault;
    late DesktopGoogleAuth auth;

    setUp(() async {
      google = GoogleServer()
        ..codes.add('first')
        ..tokens['first'] = {'access_token': 'a1', 'expires_in': 3600, 'refresh_token': 'r1', 'scope': _basic}
        ..refreshes['r1'] = {'access_token': 'a1b', 'expires_in': 3600, 'scope': _basic}
        ..emails['a1'] = 'owner@example.com';
      vault = MemoryVault();
      auth = google.auth(vault);
    });

    test('a sign-in without the Drive box stays signed in, but hands out no Drive token', () async {
      final user = await auth.signIn();
      expect(user.email, 'owner@example.com');
      expect(auth.user, isNotNull);
      expect(auth.driveAllowed, isFalse);
      expect(vault.data!['drive'], isFalse);
      await expectLater(auth.accessToken(), _fails('no_drive'));
      await expectLater(auth.accessToken(refresh: true), _fails('no_drive'));
      expect(auth.user, isNotNull, reason: 'still signed in');
    });

    test('"Allow Google Drive" asks the same account again; the old refresh token stays if Google sends none', () async {
      await auth.signIn();
      google
        ..codes.add('second')
        ..tokens['second'] = {'access_token': 'a2', 'expires_in': 3600, 'scope': _withDrive}
        ..emails['a2'] = 'Owner@Example.com';
      await auth.allowDrive();
      expect(auth.driveAllowed, isTrue);
      expect(await auth.accessToken(), 'a2');
      expect(vault.data!['refresh'], 'r1');
      expect(vault.data!['drive'], isTrue);
      expect((vault.data!['user'] as Map)['email'], 'owner@example.com');
      final asked = google.asked.last.queryParameters;
      expect(asked['prompt'], 'consent');
      expect(asked['login_hint'], 'owner@example.com');
      expect(asked['include_granted_scopes'], 'true');
      expect(asked['scope'], contains(driveScope));

      // A new refresh token, when Google sends one, replaces the old.
      google
        ..codes.add('third')
        ..tokens['third'] = {'access_token': 'a3', 'expires_in': 3600, 'refresh_token': 'r3', 'scope': _withDrive}
        ..emails['a3'] = 'owner@example.com';
      await auth.allowDrive();
      expect(vault.data!['refresh'], 'r3');
    });

    test('"Allow Google Drive" answered with another account changes nothing', () async {
      await auth.signIn();
      final before = Map<String, dynamic>.from(vault.data!);
      google
        ..codes.add('second')
        ..tokens['second'] = {'access_token': 'x1', 'expires_in': 3600, 'refresh_token': 'rx', 'scope': _withDrive}
        ..emails['x1'] = 'someone@else.com';
      await expectLater(
          auth.allowDrive(),
          throwsA(isA<SyncException>()
              .having((e) => e.code, 'code', 'other_account')
              .having((e) => e.detail, 'detail', 'someone@else.com')));
      expect(auth.user!.email, 'owner@example.com');
      expect(auth.driveAllowed, isFalse);
      expect(vault.data, before);
      await expectLater(auth.accessToken(), _fails('no_drive'));
    });

    test('Drive unticked again: still not allowed, nothing replaced', () async {
      await auth.signIn();
      final before = Map<String, dynamic>.from(vault.data!);
      google
        ..codes.add('second')
        ..tokens['second'] = {'access_token': 'a2', 'expires_in': 3600, 'refresh_token': 'r2', 'scope': _basic}
        ..emails['a2'] = 'owner@example.com';
      await expectLater(auth.allowDrive(), _fails('no_drive'));
      expect(auth.driveAllowed, isFalse);
      expect(vault.data, before);
    });

    test('a sign-in kept by an older BizKhata finds out about Drive at start-up', () async {
      // Saved by 1.4, which never looked at what Google granted.
      vault.data = {'refresh': 'r1', 'user': {'email': 'owner@example.com'}};
      final again = google.auth(vault);
      expect((await again.restore())?.email, 'owner@example.com', reason: 'still signed in');
      expect(again.driveAllowed, isFalse);
      expect(vault.data!['drive'], isFalse);
      expect(vault.data!['refresh'], 'r1');

      // Google's answer decides each time: a refresh that carries Drive allows it.
      google.refreshes['r1'] = {'access_token': 'a9', 'expires_in': 3600, 'scope': _withDrive};
      final later = google.auth(vault);
      await later.restore();
      expect(later.driveAllowed, isTrue);
      expect(vault.data!['drive'], isTrue);
      expect(await later.accessToken(), 'a9');
    });

    test('Log out while "Allow Google Drive" is open in the browser: the old tab signs nobody back in', () async {
      await auth.signIn();
      google
        ..tokens['second'] = {'access_token': 'a2', 'expires_in': 3600, 'refresh_token': 'r2', 'scope': _withDrive}
        ..emails['a2'] = 'owner@example.com';

      // Log out is tapped while the tab is still on Google's page.
      var allowing = expectLater(auth.allowDrive(), _fails('cancelled'));
      var tab = await google.nextTab();
      await auth.signOut();
      await allowing;
      await expectLater(google.finish(tab, 'second'), throwsA(isA<SocketException>()),
          reason: 'nothing in the app waits for that tab any more');
      expect(auth.user, isNull);
      expect(vault.data, isNull);
      expect(await google.auth(vault).restore(), isNull, reason: 'still logged out at the next start');

      // Signed in again. This time the tab was finished just before Log out,
      // and Google's answer to it comes after.
      final answer = Completer<void>();
      google
        ..codes.add('first')
        ..slow['second'] = answer.future;
      await auth.signIn();
      allowing = expectLater(auth.allowDrive(), _fails('cancelled'));
      tab = await google.nextTab();
      await google.finish(tab, 'second');
      await _until(() => google.exchanged.contains('second'));
      await auth.signOut();
      answer.complete();
      await allowing;
      expect(auth.user, isNull);
      expect(vault.data, isNull);
      expect(await google.auth(vault).restore(), isNull, reason: 'still logged out at the next start');
    });

    test('a late "Allow Google Drive" answer, after Log out and another sign-in, leaves the new account alone', () async {
      await auth.signIn();
      final answer = Completer<void>();
      google
        ..tokens['second'] = {'access_token': 'a2', 'expires_in': 3600, 'refresh_token': 'r2', 'scope': _withDrive}
        ..emails['a2'] = 'owner@example.com'
        ..slow['second'] = answer.future
        ..tokens['other'] = {'access_token': 'b1', 'expires_in': 3600, 'refresh_token': 'rb', 'scope': _withDrive}
        ..emails['b1'] = 'b@example.com';
      final allowing = expectLater(auth.allowDrive(), _fails('cancelled'));
      await google.finish(await google.nextTab(), 'second');
      await _until(() => google.exchanged.contains('second'));
      await auth.signOut();
      google.codes.add('other');
      expect((await auth.signIn()).email, 'b@example.com');

      answer.complete();
      await allowing;
      expect(auth.user!.email, 'b@example.com');
      expect(auth.driveAllowed, isTrue);
      expect(await auth.accessToken(), 'b1', reason: "the new account's shops must not sync into the old account's Drive");
      expect(vault.data!['refresh'], 'rb');
      expect((vault.data!['user'] as Map)['email'], 'b@example.com');
    });
  });
}
