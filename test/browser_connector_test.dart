import 'dart:async';
import 'dart:convert';

import 'package:bizkhata/data/biz.dart';
import 'package:bizkhata/data/seed.dart';
import 'package:bizkhata/web/browser_connector.dart';
import 'package:bizkhata/web/browser_page.dart';
import 'package:bizkhata/web/connectors.dart';
import 'package:bizkhata/web/order_finder.dart';
import 'package:bizkhata/web/website_sync.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

/// A website's admin panel as the hidden browser sees it. Opening the orders
/// page makes the panel ask for its "pending" tab with its sign-in token, and
/// asking again only works with that token.
class FakeSite implements PageClient {
  /// Newest first, like most admin panels.
  final orders = <Map<String, dynamic>>[];
  String token = 'Bearer good';
  bool signedIn = true;
  bool ignorePage = false;

  /// When set, every reply is this (a login page) instead of data.
  String? html;
  final opened = <Uri>[];
  final asked = <Uri>[];
  List<PageTable> pageTables = const [];
  final _out = StreamController<Captured>.broadcast();

  static const panel = 'https://admin.shop.test/orders';
  static const api = 'https://api.shop.test/api/orders';

  @override
  Stream<Captured> get captured => _out.stream;

  (int, String) reply(Uri u, Map<String, String> headers) {
    if (html != null) return (200, html!);
    if (!signedIn || headers['Authorization'] != token) return (401, '{"message":"Not authorized"}');
    if (u.path != '/api/orders') return (404, '{}');
    var rows = orders;
    final status = u.queryParameters['status'];
    if (status != null) rows = rows.where((o) => o['status'] == status).toList();
    final limit = int.tryParse(u.queryParameters['limit'] ?? '') ?? 10;
    final page = ignorePage ? 1 : int.tryParse(u.queryParameters['page'] ?? '') ?? 1;
    final slice = rows.skip((page - 1) * limit).take(limit).toList();
    return (200, jsonEncode({'orders': slice, 'page': page, 'pages': (rows.length / limit).ceil()}));
  }

  Captured panelRequest() {
    final u = Uri.parse('$api?status=pending&page=1&limit=10');
    final h = signedIn ? {'Authorization': token} : <String, String>{};
    final (status, body) = reply(u, h);
    return Captured(url: u, method: 'GET', status: status, headers: h, withCredentials: false, body: body);
  }

  @override
  Future<void> open(Uri url) async {
    opened.add(url);
    _out.add(panelRequest());
    await Future<void>.delayed(Duration.zero);
  }

  @override
  Future<FetchResult> get(Uri url, {Map<String, String> headers = const {}, bool withCredentials = false}) async {
    asked.add(url);
    final (status, body) = reply(url, headers);
    return FetchResult(status, html != null ? 'text/html' : 'application/json', body);
  }

  @override
  Future<List<PageTable>> tables() async => pageTables;

  @override
  Future<void> dispose() => _out.close();
}

const _statuses = ['pending', 'accepted', 'shipped', 'delivered'];

Map<String, dynamic> siteOrder(int n, DateTime created, {String? status, DateTime? updated}) => {
      '_id': 'o$n',
      'invoiceNo': 'INV-$n',
      'status': status ?? _statuses[n % 4],
      'shipping': {'fullName': 'Customer $n', 'phone': '017110${'$n'.padLeft(5, '0')}', 'address': 'House $n, Mirpur', 'city': 'Dhaka'},
      'items': [
        {'name': 'Rice 5kg', 'qty': 1, 'price': 390},
      ],
      'deliveryFee': 60,
      'total': 450,
      'createdAt': created.toUtc().toIso8601String(),
      'updatedAt': (updated ?? created).toUtc().toIso8601String(),
    };

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late Biz biz;
  late FakeSite site;
  final now = DateTime.now().toUtc();

  setUp(() async {
    biz = Biz(AppDatabase(NativeDatabase.memory()));
    await seedBusiness(biz, name: 'Shop', typeId: 'grocery', bangla: false);
    site = FakeSite();
    // 120 orders, one a day, newest first.
    for (var i = 0; i < 120; i++) {
      site.orders.add(siteOrder(i, now.subtract(Duration(days: i, hours: 1))));
    }
  });

  /// What the visible browser does when the owner taps "Check and use".
  Future<BrowserSource> choose() async {
    final cap = site.panelRequest();
    final found = findOrderLists(cap.json()).single;
    final list = await buildList(site, cap, found);
    return BrowserSource(pageUrl: FakeSite.panel, lists: [list]);
  }

  WebsiteConfig cfgFor(BrowserSource s) =>
      WebsiteConfig(platform: 'browser', url: 'https://admin.shop.test', browser: s, importFrom: DateTime.utc(2025, 1, 1), enabled: true);

  Future<WebsiteReport> run(WebsiteConfig cfg) async {
    final conn = cfg.connector(page: site) as BrowserConnector;
    try {
      return await WebsiteSync(biz, conn).run(cfg, maxPages: 400);
    } finally {
      await conn.close();
    }
  }

  test('a list seen in the panel becomes one BizKhata can ask for again: all statuses, bigger pages, paging', () async {
    final s = await choose();
    final l = s.lists.single;
    final u = Uri.parse(l.url);
    expect(u.queryParameters.containsKey('status'), isFalse, reason: 'every status, not just the open tab');
    expect(u.queryParameters['limit'], '50');
    expect(l.pageParam, 'page');
    expect(l.firstPage, 1);
    expect(l.arrayPath, 'orders');
    expect(l.oldestFirst, isFalse);
    expect(l.urlForPage(2).queryParameters['page'], '3');
  });

  test('the source and its column choices survive being saved', () async {
    final cfg = cfgFor(await choose());
    final back = WebsiteConfig.fromJson(jsonDecode(jsonEncode(cfg.toJson())) as Map<String, dynamic>);
    expect(back.isBrowser, isTrue);
    expect(back.ready, isTrue);
    expect(back.canPush, isFalse, reason: 'read-only: nothing is sent to the website');
    expect(back.products, isTrue, reason: 'the settings page turns products off; the config keeps what it was given');
    expect(back.browser!.lists.single.mapping.fields, cfg.browser!.lists.single.mapping.fields);
    expect(back.connector(page: site), isA<BrowserConnector>());
  });

  test('reads every page the first time, then only recent ones; follows status changes; no duplicates', () async {
    final cfg = cfgFor(await choose());
    final first = await run(cfg);
    expect(first.created, 120);
    expect(first.errors, isEmpty);
    expect(site.asked.where((u) => u.queryParameters['page'] == '3'), isNotEmpty);
    final sales = await biz.db.select(biz.db.sales).get();
    expect(sales, hasLength(120));
    expect(sales.where((s) => s.status == 'delivered'), hasLength(30));

    // Later: order o1 (shipped) is delivered on the website, and a new order comes in.
    site.orders[1] = siteOrder(1, now.subtract(const Duration(days: 1, hours: 1)), status: 'delivered', updated: now);
    site.orders.insert(0, siteOrder(500, now));
    site.asked.clear();
    final second = await run(cfg);
    expect(second.created, 1);
    expect(second.updated, 1);
    expect(site.asked.where((u) => u.queryParameters['page'] == '3'), isEmpty, reason: 'orders older than 45 days are not read again');
    final link = await (biz.db.select(biz.db.extLinks)..where((t) => t.extId.equals('o1'))).getSingle();
    expect((await biz.sales.byId(link.localId))!.status, 'delivered');
    expect(await biz.db.select(biz.db.sales).get(), hasLength(121));

    // Nothing changed: nothing written.
    final third = await run(cfg);
    expect(third.created + third.updated, 0);
  });

  test('signed out: says so (after trying the page once more)', () async {
    final cfg = cfgFor(await choose());
    site.signedIn = false;
    await expectLater(run(cfg), throwsA(isA<WebsiteException>().having((e) => e.code, 'code', 'signed_out')));
    expect(site.opened, hasLength(2), reason: 'the page is opened again once in case the sign-in was renewed');
  });

  test('a login page instead of data counts as signed out', () async {
    final cfg = cfgFor(await choose());
    site.html = '<!doctype html><html><body><form>Password</form></body></html>';
    await expectLater(run(cfg), throwsA(isA<WebsiteException>().having((e) => e.code, 'code', 'signed_out')));
  });

  test('a website that ignores the page number is read once, not forever', () async {
    final cfg = cfgFor(await choose());
    site.ignorePage = true;
    site.asked.clear();
    final rep = await run(cfg);
    expect(rep.created, 50);
    expect(site.asked, hasLength(2), reason: 'page 2 gave the same orders as page 1, so it stopped there');
  });

  test('a table on a page (websites whose admin panel is plain pages)', () async {
    site.pageTables = [
      const PageTable(['SL', 'Invoice', 'Date', 'Customer', 'Phone', 'Amount', 'Status'], [
        ['1', 'T-1', '10/11/2026', 'Rahim', '01711111111', '৳ 1,250', 'Pending'],
        ['2', 'T-2', '09/11/2026', 'Karim', '01811111111', '৳ 980', 'Delivered'],
      ]),
    ];
    final t = site.pageTables.first;
    final found = judgeRows(t.asRows())!;
    final src = BrowserSource(pageUrl: FakeSite.panel, lists: [tableList(Uri.parse('https://admin.shop.test/orders?page=1'), t, found.mapping)]);
    final rep = await run(cfgFor(src));
    expect(rep.created, 2);
    final s = await biz.db.select(biz.db.sales).get();
    expect(s.map((x) => x.total), containsAll([1250.0, 980.0]));
  });

  test('pasted orders come in once and leave the website reading position alone', () async {
    final (h, r) = parsePastedTable('Invoice\tCustomer\tPhone\tTotal\tStatus\nP-1\tRahim\t01711111111\t1250\tPending\nP-2\tKarim\t01811111111\t980\tShipped\n');
    final orders = judgeRows(tableRows(h, r))!.orders();
    final sync = WebsiteSync(biz, ListConnector(orders));
    final rep = await sync.importOrders(orders, const WebsiteConfig(platform: 'browser'));
    expect(rep.created, 2);
    expect(await biz.settings.getOr(WebKeys.orderCursor, ''), '');
    final again = await sync.importOrders(orders, const WebsiteConfig(platform: 'browser'));
    expect(again.created, 0, reason: 'pasting the same table twice brings nothing twice');
  });
}
