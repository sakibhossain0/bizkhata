import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:ffi/ffi.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import 'sync_engine.dart';

/// OAuth client ids, compiled in with `--dart-define-from-file=google_oauth.json`
/// (see docs/google-setup.md). Without them the Google features stay hidden.
abstract final class GoogleConfig {
  static const desktopClientId = String.fromEnvironment('GOOGLE_DESKTOP_CLIENT_ID');
  static const desktopClientSecret = String.fromEnvironment('GOOGLE_DESKTOP_CLIENT_SECRET');
  static const webClientId = String.fromEnvironment('GOOGLE_WEB_CLIENT_ID');

  static bool get ready => Platform.isAndroid ? webClientId.isNotEmpty : desktopClientId.isNotEmpty;
}

/// Only the app's own hidden Drive folder, plus name and email to show who is signed in.
const driveScope = 'https://www.googleapis.com/auth/drive.appdata';
const googleScopes = ['openid', 'email', 'profile', driveScope];

class GoogleUser {
  final String email;
  final String? name;
  final String? photoUrl;
  const GoogleUser(this.email, {this.name, this.photoUrl});

  Map<String, String?> toJson() => {'email': email, 'name': name, 'photo': photoUrl};
  static GoogleUser? fromJson(Object? j) {
    if (j is! Map || j['email'] is! String) return null;
    return GoogleUser(j['email'] as String, name: j['name'] as String?, photoUrl: j['photo'] as String?);
  }
}

abstract class GoogleAuth {
  factory GoogleAuth.forPlatform() => Platform.isAndroid ? AndroidGoogleAuth() : DesktopGoogleAuth();

  bool get configured;
  GoogleUser? get user;

  /// Google lets BizKhata use its own hidden folder in this account's Drive.
  /// Google's consent page lets people untick that and still sign in.
  bool get driveAllowed;

  /// Signed in before on this device? Done quietly, no window.
  Future<GoogleUser?> restore();

  /// Opens Google's sign-in (a browser tab on Windows, the account picker on Android).
  Future<GoogleUser> signIn();

  /// Asks the signed-in account for Google Drive again. Throws [SyncException]
  /// `no_drive` if it is still refused, `other_account` (with that email) if
  /// a different account was picked on Google's page.
  Future<void> allowDrive();

  /// Stop waiting for a Google page that is still open (Windows: its tab may
  /// have been closed without finishing). The waiting call ends with
  /// `cancelled`. Android's pages are system dialogs, so nothing to do there.
  void cancelPendingConsent();

  Future<void> signOut();

  /// A valid token for Google Drive; throws [SyncException] `not_signed_in`,
  /// or `no_drive` when Drive isn't allowed.
  Future<String> accessToken({bool refresh = false});
}

// ----------------------------------------------------------------------- Android

class AndroidGoogleAuth implements GoogleAuth {
  final _gsi = GoogleSignIn.instance;
  bool _ready = false;
  GoogleSignInAccount? _account;
  String? _token;
  bool _drive = false;

  @override
  GoogleUser? user;

  @override
  bool get configured => GoogleConfig.webClientId.isNotEmpty;

  @override
  bool get driveAllowed => _account != null && _drive;

  Future<void> _init() async {
    if (_ready) return;
    await _gsi.initialize(serverClientId: GoogleConfig.webClientId);
    _ready = true;
  }

  GoogleUser _toUser(GoogleSignInAccount a) => GoogleUser(a.email, name: a.displayName, photoUrl: a.photoUrl);

  @override
  Future<GoogleUser?> restore() async {
    if (!configured) return null;
    await _init();
    final a = _account = await (_gsi.attemptLightweightAuthentication() ?? Future<GoogleSignInAccount?>.value());
    if (a == null) return user = null;
    // Quietly, without a dialog: was Drive allowed before?
    try {
      _token = (await a.authorizationClient.authorizationForScopes(const [driveScope]))?.accessToken;
      _drive = _token != null;
    } catch (_) {
      // Offline or Play services busy: the first Drive call finds out.
      _drive = true;
    }
    return user = _toUser(a);
  }

  @override
  Future<GoogleUser> signIn() async {
    if (!configured) throw SyncException('not_configured');
    await _init();
    final a = await _gsi.authenticate(scopeHint: const [driveScope]);
    _account = a;
    _token = null;
    _drive = false;
    try {
      await _authorize(a);
    } catch (_) {
      // Drive declined: still signed in; the app asks for Drive again later.
    }
    return user = _toUser(a);
  }

  Future<void> _authorize(GoogleSignInAccount a) async {
    _token = (await a.authorizationClient.authorizeScopes(const [driveScope])).accessToken;
    _drive = true;
  }

  @override
  Future<void> allowDrive() async {
    final a = _account;
    if (a == null) throw SyncException('not_signed_in');
    // Android asks for the signed-in account only, so no other account can answer.
    try {
      await _authorize(a);
    } on GoogleSignInException {
      throw SyncException('no_drive');
    }
  }

  @override
  Future<String> accessToken({bool refresh = false}) async {
    final a = _account;
    if (a == null) throw SyncException('not_signed_in');
    if (refresh && _token != null) {
      await a.authorizationClient.clearAuthorizationToken(accessToken: _token!);
      _token = null;
    }
    if (_token != null) return _token!;
    final auth = await a.authorizationClient.authorizationForScopes(const [driveScope]);
    // Still signed in, only without Drive.
    _drive = auth != null;
    if (auth == null) throw SyncException('no_drive');
    return _token = auth.accessToken;
  }

  @override
  void cancelPendingConsent() {}

  @override
  Future<void> signOut() async {
    await _init();
    await _gsi.signOut();
    _account = null;
    _token = null;
    _drive = false;
    user = null;
  }
}

// ----------------------------------------------------------------------- Windows / desktop

/// "Sign in with Google" for desktop apps: the system browser opens Google's
/// page and sends the answer back to a one-time server on 127.0.0.1 (OAuth
/// loopback flow with PKCE). The refresh token is kept encrypted for this
/// Windows user (DPAPI).
class DesktopGoogleAuth implements GoogleAuth {
  final String clientId;
  final String clientSecret;
  final http.Client _http;
  final Future<bool> Function(Uri url) _open;
  final TokenVault _vault;

  DesktopGoogleAuth({
    String? clientId,
    String? clientSecret,
    http.Client? client,
    Future<bool> Function(Uri url)? openBrowser,
    TokenVault? vault,
  })  : clientId = clientId ?? GoogleConfig.desktopClientId,
        clientSecret = clientSecret ?? GoogleConfig.desktopClientSecret,
        _http = client ?? http.Client(),
        _open = openBrowser ?? ((u) => launchUrl(u, mode: LaunchMode.externalApplication)),
        _vault = vault ?? TokenVault();

  static const _authUrl = 'https://accounts.google.com/o/oauth2/v2/auth';
  static const _tokenUrl = 'https://oauth2.googleapis.com/token';
  static const _userUrl = 'https://openidconnect.googleapis.com/v1/userinfo';

  String? _access;
  DateTime? _expires;
  bool _drive = false;

  /// Bumped by every sign-in, Drive permission and sign-out, so a token
  /// refresh that was under way meanwhile can't bring back what it replaced.
  int _generation = 0;

  /// The one-time servers still waiting for Google's page. Signing out closes
  /// them, so a browser tab left open can't sign anyone back in.
  final _waiting = <HttpServer>{};

  @override
  GoogleUser? user;

  @override
  bool get configured => clientId.isNotEmpty;

  @override
  bool get driveAllowed => user != null && _drive;

  static String _random(int n) {
    const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~';
    final r = Random.secure();
    return List.generate(n, (_) => chars[r.nextInt(chars.length)]).join();
  }

  /// Whether a token answer from Google carries Drive; null if it doesn't say.
  /// People can untick Drive on the consent page, and the answer's "scope"
  /// (sent with the first token and with every refresh) lists what was granted.
  static bool? _grantsDrive(Map<String, dynamic> tokens) {
    final scope = tokens['scope'];
    return scope is String ? scope.split(' ').contains(driveScope) : null;
  }

  @override
  Future<GoogleUser?> restore() async {
    if (!configured) return null;
    final saved = await _vault.read();
    if (saved == null) return null;
    user = GoogleUser.fromJson(saved['user']);
    // Not saved by BizKhata 1.4 and older; the refresh below finds out.
    _drive = saved['drive'] != false;
    try {
      await accessToken(refresh: true);
    } on SyncException catch (e) {
      if (e.code == 'not_signed_in') {
        user = null;
        _drive = false;
        return null;
      }
      // Offline, or signed in without Drive: keep the account; sync retries later.
    }
    return user;
  }

  @override
  Future<GoogleUser> signIn() async {
    if (!configured) throw SyncException('not_configured');
    final tokens = await _consent(prompt: 'consent select_account');
    final refreshToken = tokens['refresh_token'] as String?;
    if (refreshToken == null) throw SyncException('network', 'Google did not return a refresh token');
    final me = await _whoIs(tokens);
    _generation++;
    _drive = true; // what was asked for, unless Google's answer says otherwise
    _remember(tokens);
    user = me;
    await _vault.write({'refresh': refreshToken, 'user': me.toJson(), 'drive': _drive});
    return me;
  }

  @override
  Future<void> allowDrive() async {
    final me = user;
    if (me == null) throw SyncException('not_signed_in');
    final generation = _generation;
    final tokens = await _consent(prompt: 'consent', loginHint: me.email, addToGranted: true);
    _stillSignedIn(generation, me);
    // Google's page lets people pick any account: only the signed-in one may
    // change anything here.
    final who = await _whoIs(tokens);
    _stillSignedIn(generation, me);
    if (who.email.trim().toLowerCase() != me.email.trim().toLowerCase()) {
      throw SyncException('other_account', who.email);
    }
    if (_grantsDrive(tokens) == false) throw SyncException('no_drive');
    final saved = await _vault.read();
    _stillSignedIn(generation, me);
    // Google doesn't always send a new refresh token; the old one then stays good.
    final refreshToken = tokens['refresh_token'] as String? ?? saved?['refresh'] as String?;
    if (refreshToken == null) throw SyncException('not_signed_in');
    _generation++;
    _drive = true;
    _remember(tokens);
    await _vault.write({...?saved, 'refresh': refreshToken, 'user': me.toJson(), 'drive': true});
  }

  /// Google's page can stay open for minutes. An answer that comes after Log
  /// out, or after another sign-in, belongs to someone no longer signed in here.
  void _stillSignedIn(int generation, GoogleUser me) {
    if (generation != _generation || user?.email != me.email) throw SyncException('cancelled');
  }

  /// Google's page in the system browser, which sends its answer back to a
  /// one-time server on 127.0.0.1. Returns Google's token answer for it.
  Future<Map<String, dynamic>> _consent({required String prompt, String? loginHint, bool addToGranted = false}) async {
    final verifier = _random(64);
    final challenge = base64UrlEncode(sha256.convert(ascii.encode(verifier)).bytes).replaceAll('=', '');
    final state = _random(24);
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _waiting.add(server);
    final redirect = 'http://127.0.0.1:${server.port}';
    try {
      final url = Uri.parse(_authUrl).replace(queryParameters: {
        'client_id': clientId,
        'redirect_uri': redirect,
        'response_type': 'code',
        'scope': googleScopes.join(' '),
        'code_challenge': challenge,
        'code_challenge_method': 'S256',
        'state': state,
        'access_type': 'offline',
        'prompt': prompt,
        'login_hint': ?loginHint,
        // Keep what was granted before and add what is ticked now.
        if (addToGranted) 'include_granted_scopes': 'true',
      });
      if (!await _open(url)) throw SyncException('network', 'Could not open the browser');
      final code = await _waitForCode(server, state).timeout(const Duration(minutes: 5),
          onTimeout: () => throw SyncException('cancelled'));
      return await _post({
        'code': code,
        'client_id': clientId,
        'client_secret': clientSecret,
        'redirect_uri': redirect,
        'grant_type': 'authorization_code',
        'code_verifier': verifier,
      });
    } finally {
      _waiting.remove(server);
      await server.close(force: true);
    }
  }

  /// The account a token answer belongs to.
  Future<GoogleUser> _whoIs(Map<String, dynamic> tokens) async {
    final http.Response res;
    Object? j;
    try {
      res = await _http
          .get(Uri.parse(_userUrl), headers: {'Authorization': 'Bearer ${tokens['access_token']}'})
          .timeout(const Duration(seconds: 30));
      j = jsonDecode(res.body);
    } catch (e) {
      throw SyncException('network', '$e');
    }
    if (res.statusCode != 200 || j is! Map || j['email'] is! String) {
      throw SyncException('network', 'Google did not say which account this is (${res.statusCode})');
    }
    return GoogleUser(j['email'] as String, name: j['name'] as String?, photoUrl: j['picture'] as String?);
  }

  Future<String> _waitForCode(HttpServer server, String state) async {
    await for (final req in server) {
      final q = req.uri.queryParameters;
      if (!q.containsKey('code') && !q.containsKey('error')) {
        req.response.statusCode = 404;
        await req.response.close();
        continue;
      }
      final ok = q['state'] == state && q['code'] != null;
      req.response.headers.contentType = ContentType.html;
      req.response.write('<!doctype html><meta charset="utf-8"><title>BizKhata</title>'
          '<body style="font-family:sans-serif;text-align:center;padding:60px">'
          '<h2>${ok ? 'Signed in to BizKhata ✓' : 'Sign-in was not completed'}</h2>'
          '<p>You can close this tab and go back to the app.</p></body>');
      await req.response.close();
      if (!ok) throw SyncException(q['error'] == 'access_denied' ? 'cancelled' : 'network', q['error']);
      return q['code']!;
    }
    throw SyncException('cancelled');
  }

  Future<Map<String, dynamic>> _post(Map<String, String> form) async {
    final http.Response res;
    try {
      res = await _http.post(Uri.parse(_tokenUrl), body: form).timeout(const Duration(seconds: 30));
    } catch (e) {
      throw SyncException('network', '$e');
    }
    final j = jsonDecode(res.body) as Map<String, dynamic>;
    if (res.statusCode == 400 && j['error'] == 'invalid_grant') throw SyncException('not_signed_in');
    if (res.statusCode >= 400) throw SyncException('network', '${res.statusCode} ${j['error']}');
    return j;
  }

  void _remember(Map<String, dynamic> tokens) {
    _access = tokens['access_token'] as String?;
    _expires = DateTime.now().add(Duration(seconds: (tokens['expires_in'] as num?)?.toInt() ?? 3600));
    _drive = _grantsDrive(tokens) ?? _drive;
  }

  @override
  Future<String> accessToken({bool refresh = false}) async {
    if (!refresh && _access != null && _expires != null && DateTime.now().isBefore(_expires!.subtract(const Duration(minutes: 2)))) {
      if (!_drive) throw SyncException('no_drive');
      return _access!;
    }
    final saved = await _vault.read();
    final refreshToken = saved?['refresh'] as String?;
    if (saved == null || refreshToken == null) throw SyncException('not_signed_in');
    final generation = _generation;
    final Map<String, dynamic> tokens;
    try {
      tokens = await _post({
        'client_id': clientId,
        'client_secret': clientSecret,
        'refresh_token': refreshToken,
        'grant_type': 'refresh_token',
      });
    } on SyncException catch (e) {
      // Signed in (or out) again meanwhile: the new tokens decide.
      if (generation != _generation) return accessToken();
      if (e.code == 'not_signed_in') await _vault.clear(); // revoked or expired: sign in again
      rethrow;
    }
    if (generation != _generation) return accessToken();
    _remember(tokens);
    // Saved for starts without internet (and added to sign-ins saved before it was kept).
    if (saved['drive'] != _drive) await _vault.write({...saved, 'drive': _drive});
    // A token without Drive would only be refused by Drive.
    if (!_drive) throw SyncException('no_drive');
    return _access!;
  }

  @override
  void cancelPendingConsent() {
    for (final server in _waiting.toList()) {
      unawaited(server.close(force: true));
    }
  }

  @override
  Future<void> signOut() async {
    _generation++;
    // A Google page still open in the browser (a sign-in, or "Allow Google
    // Drive" while the Log out button was tapped) has nowhere to answer now.
    cancelPendingConsent();
    final saved = await _vault.read();
    final t = saved?['refresh'] as String?;
    if (t != null) {
      try {
        await _http.post(Uri.parse('https://oauth2.googleapis.com/revoke'), body: {'token': t}).timeout(const Duration(seconds: 10));
      } catch (_) {
        // Offline: the token is forgotten here anyway.
      }
    }
    await _vault.clear();
    _access = null;
    _expires = null;
    _drive = false;
    user = null;
  }
}

/// Keeps the Google refresh token. On Windows it is encrypted with DPAPI, so
/// only the same Windows user on the same PC can read it.
class TokenVault {
  static const _key = 'google_auth';

  Future<Map<String, dynamic>?> read() async {
    final raw = (await SharedPreferences.getInstance()).getString(_key);
    if (raw == null) return null;
    try {
      final text = Platform.isWindows ? utf8.decode(_Dpapi.unprotect(base64Decode(raw))) : raw;
      return Map<String, dynamic>.from(jsonDecode(text) as Map);
    } catch (_) {
      return null; // copied from another PC or damaged: treat as signed out
    }
  }

  Future<void> write(Map<String, dynamic> data) async {
    final text = jsonEncode(data);
    final stored = Platform.isWindows ? base64Encode(_Dpapi.protect(utf8.encode(text))) : text;
    await (await SharedPreferences.getInstance()).setString(_key, stored);
  }

  Future<void> clear() async => (await SharedPreferences.getInstance()).remove(_key);
}

// Windows DPAPI (crypt32.dll) through dart:ffi.

final class _Blob extends Struct {
  @Uint32()
  external int cbData;
  external Pointer<Uint8> pbData;
}

typedef _CryptNative = Int32 Function(
    Pointer<_Blob>, Pointer<Void>, Pointer<_Blob>, Pointer<Void>, Pointer<Void>, Uint32, Pointer<_Blob>);
typedef _CryptDart = int Function(
    Pointer<_Blob>, Pointer<Void>, Pointer<_Blob>, Pointer<Void>, Pointer<Void>, int, Pointer<_Blob>);
typedef _LocalFreeNative = Pointer<Void> Function(Pointer<Void>);
typedef _LocalFreeDart = Pointer<Void> Function(Pointer<Void>);

abstract final class _Dpapi {
  static const _uiForbidden = 0x1;
  static final _crypt32 = DynamicLibrary.open('crypt32.dll');
  static final _kernel32 = DynamicLibrary.open('kernel32.dll');
  static final _protect = _crypt32.lookupFunction<_CryptNative, _CryptDart>('CryptProtectData');
  static final _unprotect = _crypt32.lookupFunction<_CryptNative, _CryptDart>('CryptUnprotectData');
  static final _localFree = _kernel32.lookupFunction<_LocalFreeNative, _LocalFreeDart>('LocalFree');

  static List<int> protect(List<int> data) => _run(_protect, data);
  static List<int> unprotect(List<int> data) => _run(_unprotect, data);

  static List<int> _run(_CryptDart fn, List<int> data) {
    final input = calloc<_Blob>();
    final output = calloc<_Blob>();
    final bytes = calloc<Uint8>(data.isEmpty ? 1 : data.length);
    try {
      bytes.asTypedList(data.length).setAll(0, data);
      input.ref
        ..cbData = data.length
        ..pbData = bytes;
      if (fn(input, nullptr, nullptr, nullptr, nullptr, _uiForbidden, output) == 0) {
        throw StateError('DPAPI failed');
      }
      final result = List<int>.of(output.ref.pbData.asTypedList(output.ref.cbData));
      _localFree(output.ref.pbData.cast());
      return result;
    } finally {
      calloc.free(bytes);
      calloc.free(input);
      calloc.free(output);
    }
  }
}
