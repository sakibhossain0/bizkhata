// Drives the real built-in browser (WebView2 on Windows) against a small
// fake website served from this test: a login page that signs in by itself
// (standing in for the owner typing), and an orders page that, like most
// admin panels, asks its API for the list with the sign-in token.
//
//   flutter test integration_test/browser_test.dart -d windows
import 'dart:convert';
import 'dart:io';

import 'package:bizkhata/core/theme.dart';
import 'package:bizkhata/web/browser_connector.dart';
import 'package:bizkhata/web/browser_page.dart';
import 'package:bizkhata/web/order_finder.dart';
import 'package:bizkhata/ui/screens/website_browser.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:intl/date_symbol_data_local.dart';

const _token = 'tok-123';

final _orders = [
  for (var i = 0; i < 70; i++)
    {
      '_id': 'o$i',
      'invoiceNo': 'INV-${1000 + i}',
      'status': ['pending', 'accepted', 'shipped', 'delivered'][i % 4],
      'shipping': {'fullName': 'Customer $i', 'phone': '017110${'$i'.padLeft(5, '0')}', 'address': 'House $i, Mirpur', 'city': 'Dhaka'},
      'items': [
        {'name': 'Rice 5kg', 'qty': 1, 'price': 390},
      ],
      'deliveryFee': 60,
      'total': 450,
      'createdAt': DateTime.utc(2026, 11, 10).subtract(Duration(days: i)).toIso8601String(),
    },
];

const _loginPage = '''<!doctype html><html><body>
<h1>Shop admin</h1>
<form id="f"><input id="u" name="email"><input id="p" name="password" type="password"><button id="go">Sign in</button></form>
<script>
document.getElementById('f').addEventListener('submit', function (e) {
  e.preventDefault();
  fetch('/api/login', {method: 'POST', headers: {'Content-Type': 'application/json'},
    body: JSON.stringify({email: document.getElementById('u').value, password: document.getElementById('p').value})})
    .then(function (r) { return r.json(); })
    .then(function (j) { localStorage.setItem('token', j.token); location.href = '/orders'; });
});
// Standing in for the owner typing their own password.
setTimeout(function () {
  document.getElementById('u').value = 'owner@shop.test';
  document.getElementById('p').value = 'not-a-real-password';
  document.getElementById('go').click();
}, 400);
</script></body></html>''';

const _ordersPage = '''<!doctype html><html><body>
<h1>Orders</h1><table id="t"><thead><tr><th>Invoice</th><th>Customer</th><th>Phone</th><th>Total</th><th>Status</th></tr></thead><tbody></tbody></table>
<script>
var token = localStorage.getItem('token');
if (!token) { location.href = '/login'; }
else {
  var x = new XMLHttpRequest();
  x.open('GET', '/api/orders?status=pending&page=1&limit=10');
  x.setRequestHeader('Authorization', 'Bearer ' + token);
  x.onload = function () {
    var j = JSON.parse(x.responseText);
    document.querySelector('#t tbody').innerHTML = j.orders.map(function (o) {
      return '<tr><td>' + o.invoiceNo + '</td><td>' + o.shipping.fullName + '</td><td>' + o.shipping.phone + '</td><td>' + o.total + '</td><td>' + o.status + '</td></tr>';
    }).join('');
  };
  x.send();
}
</script></body></html>''';

Future<HttpServer> _serve() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((req) async {
    final res = req.response;
    final path = req.uri.path;
    if (path == '/login' || path == '/orders') {
      res.headers.contentType = ContentType.html;
      res.write(path == '/login' ? _loginPage : _ordersPage);
    } else if (path == '/api/login' && req.method == 'POST') {
      await utf8.decoder.bind(req).join();
      res.headers.contentType = ContentType.json;
      res.write(jsonEncode({'token': _token}));
    } else if (path == '/api/orders') {
      if (req.headers.value('authorization') != 'Bearer $_token') {
        res.statusCode = 401;
        res.write('{"message":"Not authorized"}');
      } else {
        var rows = _orders;
        final st = req.uri.queryParameters['status'];
        if (st != null) rows = rows.where((o) => o['status'] == st).toList();
        final limit = int.tryParse(req.uri.queryParameters['limit'] ?? '') ?? 10;
        final page = int.tryParse(req.uri.queryParameters['page'] ?? '') ?? 1;
        res.headers.contentType = ContentType.json;
        res.write(jsonEncode({'orders': rows.skip((page - 1) * limit).take(limit).toList(), 'pages': (rows.length / limit).ceil()}));
      }
    } else {
      res.statusCode = 404;
    }
    await res.close();
  });
  return server;
}

Future<void> _until(WidgetTester t, Finder f, {Duration timeout = const Duration(seconds: 40)}) async {
  final end = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(end)) {
    await t.pump(const Duration(milliseconds: 200));
    if (f.evaluate().isNotEmpty) return;
  }
  throw TestFailure('timed out waiting for $f');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  late HttpServer server;
  late String base;
  late Directory profile;

  setUpAll(() async {
    // As main() does in the app.
    await initializeDateFormatting('en');
    await initializeDateFormatting('bn');
    server = await _serve();
    base = 'http://127.0.0.1:${server.port}';
    profile = await Directory.systemTemp.createTemp('bk_browser_');
  });

  tearDownAll(() async {
    await server.close(force: true);
  });

  testWidgets('sign in, spot the orders list, check it and choose it', (t) async {
    expect(await BrowserProfile.engineVersion(), isNotNull, reason: 'WebView2 runtime');
    BrowserSource? picked;
    await t.pumpWidget(ProviderScope(
      child: MaterialApp(
        theme: buildTheme(), // the app's own (floating toasts and all)
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: FilledButton(
                onPressed: () async => picked = await WebsiteBrowserScreen.open(context, startUrl: '$base/login', folder: profile.path),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    ));
    await t.tap(find.text('open'));
    // Login page signs in → orders page → its XHR is seen and recognised.
    await _until(t, find.byKey(const ValueKey('browser-found')));
    expect(find.textContaining('orders found'), findsOneWidget);

    await t.tap(find.byKey(const ValueKey('browser-use')));
    await _until(t, find.byKey(const ValueKey('preview-use')));
    expect(find.text('INV-1000'), findsOneWidget, reason: 'the preview shows the first order');
    await t.tap(find.byKey(const ValueKey('preview-use')));
    // The list is checked inside the page (all statuses, 50 a page, paging).
    final done = find.byKey(const ValueKey('browser-done'));
    final end = DateTime.now().add(const Duration(seconds: 40));
    while ((t.widget(done) as ButtonStyleButton).onPressed == null && DateTime.now().isBefore(end)) {
      await t.pump(const Duration(milliseconds: 200));
    }
    await t.tap(done);
    await t.pumpAndSettle(const Duration(milliseconds: 200));

    expect(picked, isNotNull);
    final l = picked!.lists.single;
    final u = Uri.parse(l.url);
    expect(u.path, '/api/orders');
    expect(u.queryParameters.containsKey('status'), isFalse);
    expect(u.queryParameters['limit'], '50');
    expect(l.pageParam, 'page');
    expect(picked!.pageUrl, '$base/orders');
  });

  testWidgets('the hidden browser reads every order with the website\'s own sign-in', (t) async {
    final env = await BrowserProfile.environment(profile.path);
    final page = HiddenPage(env);
    try {
      // The source the owner chose above, written out.
      final cap = Captured(
        url: Uri.parse('$base/api/orders?page=1&limit=50'),
        method: 'GET',
        status: 200,
        headers: const {},
        withCredentials: false,
        body: jsonEncode({'orders': _orders.take(50).toList()}),
      );
      final found = findOrderLists(cap.json()).single;
      expect(found.rows, hasLength(50));
      final list = OrderList(
        kind: 'json',
        url: '$base/api/orders?page=1&limit=50',
        arrayPath: found.path,
        mapping: found.mapping,
        pageParam: 'page',
      );
      final conn = BrowserConnector(source: BrowserSource(pageUrl: '$base/orders', lists: [list]), page: page);
      final first = await conn.orders(page: 1);
      final second = await conn.orders(page: 2);
      expect(first.items, hasLength(50));
      expect(second.items, hasLength(20));
      expect(second.more, isFalse);
      expect(first.items.first.phone, '01711000000');

      // And a plain table on the page.
      final tables = await page.tables();
      expect(tables.single.headers, ['Invoice', 'Customer', 'Phone', 'Total', 'Status']);
      expect(tables.single.rows, hasLength(10));
      await conn.close();
    } finally {
      await page.dispose();
    }
  });
}
