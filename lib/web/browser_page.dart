import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show Size;

import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import 'order_finder.dart';

/// The script put into every page of the built-in browser before the page's
/// own scripts run. It copies each JSON reply the page receives (from fetch or
/// XMLHttpRequest) to BizKhata, with the request's headers so the same list
/// can be asked for again, and adds two helpers: `__bkTables()` reads the
/// tables on the page and `__bkGet()` asks for an address from inside the page
/// (with its cookies). It never changes what the page sends or shows, and it
/// never copies what the page sends (so a sign-in form's password never
/// reaches BizKhata), only the replies.
const captureScript = r'''
(function () {
  if (window.__bkCapture) return;
  window.__bkCapture = true;
  var MAX = 8 * 1024 * 1024;
  var queue = [];
  function ready() { return window.flutter_inappwebview && window.flutter_inappwebview.callHandler; }
  function flush() {
    if (!ready()) return false;
    while (queue.length) { try { window.flutter_inappwebview.callHandler('bk', queue.shift()); } catch (e) {} }
    return true;
  }
  function post(o) {
    queue.push(o);
    if (queue.length > 30) queue.shift();
    if (!flush()) { setTimeout(flush, 250); setTimeout(flush, 1500); setTimeout(flush, 5000); }
  }
  window.addEventListener('flutterInAppWebViewPlatformReady', flush);
  function looks(t) {
    if (typeof t !== 'string' || t.length < 20 || t.length > MAX) return false;
    var c = t.replace(/^\s+/, '').charAt(0);
    return (c === '{' || c === '[') && t.indexOf('{') >= 0;
  }
  function abs(u) { try { return new URL(u, location.href).href; } catch (e) { return String(u); } }
  var realFetch = window.fetch;
  if (realFetch) {
    window.fetch = function (input, init) {
      var url = '', method = 'GET', headers = {}, cred = false;
      try {
        url = typeof input === 'string' ? input : (input && input.url) || String(input);
        method = String((init && init.method) || (input && input.method) || 'GET').toUpperCase();
        var h = new Headers((init && init.headers) || (input && typeof input !== 'string' && input.headers) || {});
        h.forEach(function (v, k) { headers[k] = v; });
        cred = ((init && init.credentials) || (input && input.credentials)) === 'include';
      } catch (e) {}
      var p = realFetch.apply(window, arguments);
      p.then(function (res) {
        try {
          res.clone().text().then(function (t) {
            if (looks(t)) post({ url: abs(url), method: method, status: res.status, headers: headers, cred: cred, body: t });
          }).catch(function () {});
        } catch (e) {}
      }).catch(function () {});
      return p;
    };
  }
  var XO = XMLHttpRequest.prototype.open, XS = XMLHttpRequest.prototype.send, XH = XMLHttpRequest.prototype.setRequestHeader;
  XMLHttpRequest.prototype.open = function (m, u) {
    try { this.__bk = { method: String(m || 'GET').toUpperCase(), url: String(u), headers: {} }; } catch (e) {}
    return XO.apply(this, arguments);
  };
  XMLHttpRequest.prototype.setRequestHeader = function (k, v) {
    try { if (this.__bk) this.__bk.headers[k] = v; } catch (e) {}
    return XH.apply(this, arguments);
  };
  XMLHttpRequest.prototype.send = function (body) {
    var x = this, info = x.__bk;
    if (info) {
      x.addEventListener('load', function () {
        try {
          var t = null;
          if (x.responseType === '' || x.responseType === 'text') t = x.responseText;
          else if (x.responseType === 'json' && x.response != null) t = JSON.stringify(x.response);
          if (looks(t)) post({ url: abs(info.url), method: info.method, status: x.status, headers: info.headers, cred: !!x.withCredentials, body: t });
        } catch (e) {}
      });
    }
    return XS.apply(this, arguments);
  };
  function cellText(c) { return (c.innerText || c.textContent || '').replace(/\s+/g, ' ').trim(); }
  window.__bkTables = function () {
    var out = [];
    var tables = document.querySelectorAll('table');
    for (var i = 0; i < tables.length && out.length < 12; i++) {
      var t = tables[i], head = null, rows = [];
      if (t.tHead && t.tHead.rows.length) head = t.tHead.rows[t.tHead.rows.length - 1];
      for (var b = 0; b < t.tBodies.length; b++) for (var r = 0; r < t.tBodies[b].rows.length; r++) rows.push(t.tBodies[b].rows[r]);
      if (!head && rows.length && rows[0].querySelector('th')) { head = rows[0]; rows = rows.slice(1); }
      if (!head || !rows.length) continue;
      out.push({
        headers: [].map.call(head.cells, cellText),
        rows: rows.slice(0, 1000).map(function (row) { return [].map.call(row.cells, cellText); })
      });
    }
    var grids = document.querySelectorAll('[role="grid"], [role="table"], [role="treegrid"]');
    for (var g = 0; g < grids.length && out.length < 12; g++) {
      var grid = grids[g];
      if (grid.tagName === 'TABLE') continue;
      var hs = [].map.call(grid.querySelectorAll('[role="columnheader"]'), cellText);
      if (!hs.length) continue;
      var rs = [];
      [].forEach.call(grid.querySelectorAll('[role="row"]'), function (row) {
        var cells = row.querySelectorAll('[role="cell"], [role="gridcell"]');
        if (cells.length) rs.push([].map.call(cells, cellText));
      });
      if (rs.length) out.push({ headers: hs, rows: rs.slice(0, 1000) });
    }
    return JSON.stringify(out);
  };
  // "no-cache": always asks the website, but lets it answer "not changed" (304)
  // when it can, so an unchanged order list isn't downloaded again.
  window.__bkGet = function (url, headers, cred) {
    return realFetch.call(window, url, { method: 'GET', headers: headers || {}, credentials: cred ? 'include' : 'same-origin', cache: 'no-cache' })
      .then(function (r) {
        return r.text().then(function (t) {
          return JSON.stringify({ status: r.status, type: r.headers.get('content-type') || '', url: r.url, body: t.length > 4 * MAX ? '' : t });
        });
      });
  };
})();
''';

/// One reply the page received, as the capture script saw it.
class Captured {
  final Uri url;
  final String method;
  final int status;

  /// The request's own headers (the page's sign-in token among them). Kept in
  /// memory only, to ask for the same list again; never saved.
  final Map<String, String> headers;
  final bool withCredentials;
  final String body;
  final DateTime at;
  Captured({
    required this.url,
    required this.method,
    required this.status,
    required this.headers,
    required this.withCredentials,
    required this.body,
    DateTime? at,
  }) : at = at ?? DateTime.now();

  static Captured? fromJs(Object? raw) {
    if (raw is! Map) return null;
    final url = Uri.tryParse('${raw['url']}');
    if (url == null || !url.hasScheme) return null;
    return Captured(
      url: url,
      method: '${raw['method'] ?? 'GET'}'.toUpperCase(),
      status: (raw['status'] as num?)?.toInt() ?? 0,
      headers: {
        for (final e in (raw['headers'] as Map? ?? const {}).entries) '${e.key}': '${e.value}',
      },
      withCredentials: raw['cred'] == true,
      body: '${raw['body'] ?? ''}',
    );
  }

  Object? json() {
    try {
      return jsonDecode(body);
    } catch (_) {
      return null;
    }
  }
}

/// A reply to an address asked for from inside the page.
class FetchResult {
  final int status;
  final String contentType;
  final String body;
  const FetchResult(this.status, this.contentType, this.body);
  bool get ok => status >= 200 && status < 300;
  bool get looksLikeHtml => contentType.contains('html') || body.trimLeft().startsWith('<');
}

/// A table read from the page.
class PageTable {
  final List<String> headers;
  final List<List<String>> rows;
  const PageTable(this.headers, this.rows);
  List<Map<String, dynamic>> asRows() => tableRows(headers, rows);

  /// The header texts, normalised, to find the same table again later.
  String get signature => headers.map((h) => h.trim().toLowerCase()).join('|');
}

/// What the order reading needs from a page of the built-in browser.
abstract class PageClient {
  /// Replies the page receives from now on.
  Stream<Captured> get captured;

  /// Go to [url] and wait until it has loaded.
  Future<void> open(Uri url);

  /// Ask for [url] from inside the page, with its cookies and [headers].
  Future<FetchResult> get(Uri url, {Map<String, String> headers = const {}, bool withCredentials = false});

  /// The tables on the page now.
  Future<List<PageTable>> tables();
  Future<void> dispose();
}

List<PageTable> _parseTables(Object? raw) {
  final text = raw is String ? raw : null;
  if (text == null) return const [];
  try {
    return [
      for (final t in jsonDecode(text) as List)
        PageTable([for (final h in (t as Map)['headers'] as List) '$h'], [
          for (final r in t['rows'] as List) [for (final c in r as List) '$c'],
        ]),
    ];
  } catch (_) {
    return const [];
  }
}

FetchResult _parseFetch(Object? raw) {
  if (raw is! String) return const FetchResult(0, '', '');
  try {
    final j = jsonDecode(raw) as Map;
    return FetchResult((j['status'] as num?)?.toInt() ?? 0, '${j['type'] ?? ''}', '${j['body'] ?? ''}');
  } catch (_) {
    return const FetchResult(0, '', '');
  }
}

/// [PageClient] over a webview controller (the visible browser or a hidden one).
class ControllerPage implements PageClient {
  final InAppWebViewController controller;
  final StreamController<Captured> _out;
  Completer<void>? _loading;
  ControllerPage(this.controller, this._out);

  @override
  Stream<Captured> get captured => _out.stream;

  /// Call from the webview's onLoadStop.
  void loaded() {
    final c = _loading;
    if (c != null && !c.isCompleted) c.complete();
  }

  @override
  Future<void> open(Uri url) async {
    final c = _loading = Completer<void>();
    await controller.loadUrl(urlRequest: URLRequest(url: WebUri.uri(url)));
    await c.future.timeout(const Duration(seconds: 45), onTimeout: () {});
  }

  @override
  Future<FetchResult> get(Uri url, {Map<String, String> headers = const {}, bool withCredentials = false}) async {
    final res = await controller
        .callAsyncJavaScript(
          functionBody: '''
            if (window.__bkGet) return await window.__bkGet(url, headers, cred);
            const r = await fetch(url, {method: 'GET', headers: headers, credentials: cred ? 'include' : 'same-origin', cache: 'no-cache'});
            const t = await r.text();
            return JSON.stringify({status: r.status, type: r.headers.get('content-type') || '', body: t});
          ''',
          arguments: {'url': url.toString(), 'headers': headers, 'cred': withCredentials},
        )
        .timeout(const Duration(seconds: 60), onTimeout: () => null);
    if (res == null) return const FetchResult(0, '', '');
    if (res.error != null) return FetchResult(0, '', res.error!);
    return _parseFetch(res.value);
  }

  @override
  Future<List<PageTable>> tables() async {
    final raw = await controller.evaluateJavascript(source: 'window.__bkTables ? window.__bkTables() : "[]"');
    return _parseTables(raw);
  }

  @override
  Future<void> dispose() async {}
}

/// The user scripts every BizKhata browser page gets.
UnmodifiableListView<UserScript> captureScripts() => UnmodifiableListView([
      UserScript(source: captureScript, injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START, forMainFrameOnly: true),
    ]);

/// Hooks the capture script's messages up to [sink].
void listenForCaptures(InAppWebViewController c, void Function(Captured) sink) {
  c.addJavaScriptHandler(
    handlerName: 'bk',
    callback: (args) {
      final cap = args.isEmpty ? null : Captured.fromJs(args.first);
      if (cap != null) sink(cap);
      return null;
    },
  );
}

/// The browser profile (cookies, saved sign-ins) for one shop. On Windows each
/// shop gets its own folder so one shop's website login is never seen by
/// another; Android has one profile for the app.
class BrowserProfile {
  static final _envs = <String, WebViewEnvironment>{};

  /// Null on Android (and wherever a separate profile isn't needed).
  static Future<WebViewEnvironment?> environment(String folder) async {
    if (kIsWeb || !Platform.isWindows) return null;
    final existing = _envs[folder];
    if (existing != null) return existing;
    await Directory(folder).create(recursive: true);
    final env = await WebViewEnvironment.create(settings: WebViewEnvironmentSettings(userDataFolder: folder));
    _envs[folder] = env;
    return env;
  }

  /// Android has one browser profile for the whole app: on log out, forget
  /// its website sign-ins so the next Google account doesn't inherit them.
  /// (On Windows each shop has its own folder, which only its owner opens.)
  static Future<void> forgetSharedSignIns() async {
    if (kIsWeb || !Platform.isAndroid) return;
    try {
      await CookieManager.instance().deleteAllCookies();
      await WebStorageManager.instance().deleteAllData();
    } catch (_) {}
  }

  /// The installed browser engine's version, or null when it's missing
  /// (Windows without the Microsoft Edge WebView2 Runtime).
  static Future<String?> engineVersion() async {
    if (kIsWeb || !Platform.isWindows) return 'system';
    try {
      return await WebViewEnvironment.getAvailableVersion();
    } catch (_) {
      return null;
    }
  }
}

/// A hidden page that keeps checking a website's orders in the background.
class HiddenPage implements PageClient {
  final WebViewEnvironment? env;
  final _out = StreamController<Captured>.broadcast();
  HeadlessInAppWebView? _view;
  ControllerPage? _page;
  HiddenPage(this.env);

  @override
  Stream<Captured> get captured => _out.stream;

  Future<ControllerPage> _ensure() async {
    final p = _page;
    if (p != null) return p;
    final created = Completer<ControllerPage>();
    late ControllerPage page;
    final view = HeadlessInAppWebView(
      webViewEnvironment: env,
      initialSettings: InAppWebViewSettings(isInspectable: false, mediaPlaybackRequiresUserGesture: true, javaScriptEnabled: true),
      initialUserScripts: captureScripts(),
      initialSize: const Size(1280, 900),
      onWebViewCreated: (c) {
        page = ControllerPage(c, _out);
        listenForCaptures(c, (cap) {
          if (!_out.isClosed) _out.add(cap);
        });
        if (!created.isCompleted) created.complete(page);
      },
      onLoadStop: (c, url) => page.loaded(),
      onReceivedError: (c, req, err) {
        if (req.isForMainFrame ?? true) page.loaded();
      },
    );
    _view = view;
    await view.run();
    _page = await created.future.timeout(const Duration(seconds: 30));
    return _page!;
  }

  @override
  Future<void> open(Uri url) async => (await _ensure()).open(url);

  @override
  Future<FetchResult> get(Uri url, {Map<String, String> headers = const {}, bool withCredentials = false}) async =>
      (await _ensure()).get(url, headers: headers, withCredentials: withCredentials);

  @override
  Future<List<PageTable>> tables() async => (await _ensure()).tables();

  @override
  Future<void> dispose() async {
    final v = _view;
    _view = null;
    _page = null;
    await v?.dispose();
    await _out.close();
  }
}
