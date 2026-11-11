import 'dart:async';
import 'dart:convert';

import 'browser_page.dart';
import 'connectors.dart';
import 'order_finder.dart';

/// One list of orders on a website, found in the built-in browser: either a
/// reply from the website's own API (what its admin panel asks for), or a
/// table on one of its pages.
class OrderList {
  /// json | table
  final String kind;

  /// json: the address the admin panel asked for. table: the page's address.
  final String url;

  /// json: where the rows sit in the reply ('' = the reply is the list).
  final String arrayPath;

  /// table: the table's column titles, to find the same table again.
  final String? tableSig;
  final OrderMapping mapping;

  /// Paging, when the website has it: `?page=` style ...
  final String? pageParam;
  final int firstPage;

  /// ... or `?skip=` / `?offset=` style, [pageSize] rows at a time.
  final String? offsetParam;
  final int pageSize;

  /// The list starts with the oldest orders (so it can't stop early).
  final bool oldestFirst;

  const OrderList({
    required this.kind,
    required this.url,
    this.arrayPath = '',
    this.tableSig,
    required this.mapping,
    this.pageParam,
    this.firstPage = 1,
    this.offsetParam,
    this.pageSize = 0,
    this.oldestFirst = false,
  });

  bool get pageable => pageParam != null || offsetParam != null;

  /// The address for page [i] (0 = the first page).
  Uri urlForPage(int i) {
    final u = Uri.parse(url);
    if (pageParam != null) return _withQuery(u, {pageParam!: '${firstPage + i}'});
    if (offsetParam != null) {
      final start = int.tryParse(u.queryParameters[offsetParam!] ?? '') ?? 0;
      return _withQuery(u, {offsetParam!: '${start + i * pageSize}'});
    }
    return u;
  }

  /// "api.myshop.com/api/orders", for showing which list this is.
  String get label {
    final u = Uri.parse(url);
    return '${u.host}${u.path}';
  }

  Map<String, Object?> toJson() => {
        'kind': kind,
        'url': url,
        'arrayPath': arrayPath,
        'tableSig': ?tableSig,
        'mapping': mapping.toJson(),
        'pageParam': ?pageParam,
        'firstPage': firstPage,
        'offsetParam': ?offsetParam,
        'pageSize': pageSize,
        'oldestFirst': oldestFirst,
      };

  factory OrderList.fromJson(Map<String, dynamic> j) => OrderList(
        kind: j['kind'] as String? ?? 'json',
        url: j['url'] as String? ?? '',
        arrayPath: j['arrayPath'] as String? ?? '',
        tableSig: j['tableSig'] as String?,
        mapping: OrderMapping.fromJson(Map<String, dynamic>.from(j['mapping'] as Map? ?? const {})),
        pageParam: j['pageParam'] as String?,
        firstPage: (j['firstPage'] as num?)?.toInt() ?? 1,
        offsetParam: j['offsetParam'] as String?,
        pageSize: (j['pageSize'] as num?)?.toInt() ?? 0,
        oldestFirst: j['oldestFirst'] as bool? ?? false,
      );
}

/// Where a website's orders are read from, chosen once in the built-in
/// browser: the admin page to open (so the website's own sign-in is used)
/// and the order lists it showed.
class BrowserSource {
  final String pageUrl;
  final List<OrderList> lists;
  const BrowserSource({required this.pageUrl, required this.lists});

  Map<String, Object?> toJson() => {'pageUrl': pageUrl, 'lists': [for (final l in lists) l.toJson()]};

  static BrowserSource? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final lists = [
      for (final l in raw['lists'] as List? ?? const [])
        if (l is Map) OrderList.fromJson(Map<String, dynamic>.from(l)),
    ];
    final page = raw['pageUrl'] as String?;
    if (page == null || lists.isEmpty) return null;
    return BrowserSource(pageUrl: page, lists: lists);
  }
}

Uri _withQuery(Uri u, Map<String, String> changes) {
  final q = {...u.queryParameters, ...changes};
  return u.replace(queryParameters: q.isEmpty ? null : q);
}

Uri _withoutQuery(Uri u, String key) {
  final q = {...u.queryParameters}..remove(key);
  final out = Uri(scheme: u.scheme, userInfo: u.userInfo, host: u.host, port: u.hasPort ? u.port : null, path: u.path);
  return q.isEmpty ? out : out.replace(queryParameters: q);
}

/// "host/path" without the query, to match a reply to its list.
String listKey(Uri u) => '${u.host}${u.path}';

// Query names websites use for these.
const _statusParams = ['status', 'order_status', 'orderStatus', 'state', 'tab', 'filter', 'stage'];
const _pageParams = ['page', 'p', 'pg', 'pageNo', 'page_no', 'pageNumber', 'page_number', 'currentPage', 'current_page', 'pageIndex'];
const _offsetParams = ['skip', 'offset', 'start', 'from'];
const _sizeParams = ['limit', 'take', 'size', 'per_page', 'perPage', 'pageSize', 'page_size', 'length', 'count', 'rows', 'perpage'];

Object? _decode(String body) {
  try {
    return jsonDecode(body);
  } catch (_) {
    return null;
  }
}

/// Turns a list the admin panel received into one BizKhata can ask for again
/// by itself: tries the same list without a status filter (all orders, not
/// one tab), with bigger pages, and works out how its pages go.
Future<OrderList> buildList(PageClient page, Captured c, FoundList found) async {
  var url = c.url;
  var rows = found.rows;
  final mapping = found.mapping;
  final headers = c.headers;
  final cred = c.withCredentials;

  Future<List<Map<String, dynamic>>?> rowsFor(Uri u) async {
    final r = await page.get(u, headers: headers, withCredentials: cred);
    if (!r.ok) return null;
    return rowsAt(_decode(r.body), found.path);
  }

  Set<String> ids(List<Map<String, dynamic>> rs) => {for (final r in rs) ?mapping.toOrder(r)?.id};

  if (c.method == 'GET') {
    // 1. Every status, not just the tab that was open.
    for (final p in _statusParams) {
      if (!url.queryParameters.containsKey(p)) continue;
      final wider = _withoutQuery(url, p);
      final r = await rowsFor(wider);
      if (r != null && r.length >= rows.length && ids(r).length >= ids(rows).length) {
        url = wider;
        rows = r;
      }
    }
    // 2. Fifty rows at a time where the page shows fewer.
    final sizeKey = _sizeParams.where(url.queryParameters.containsKey).firstOrNull;
    final size = sizeKey == null ? null : int.tryParse(url.queryParameters[sizeKey]!);
    if (sizeKey != null && size != null && size < 50 && rows.length >= size) {
      final bigger = _withQuery(url, {sizeKey: '50'});
      final r = await rowsFor(bigger);
      if (r != null && r.length > rows.length) {
        url = bigger;
        rows = r;
      }
    }
  }

  // 3. How the pages go.
  String? pageParam;
  var firstPage = 1;
  String? offsetParam;
  var pageSize = 0;
  if (c.method == 'GET' && rows.isNotEmpty) {
    final first = ids(rows);
    final pk = _pageParams.where(url.queryParameters.containsKey).firstOrNull;
    final ok = _offsetParams.where(url.queryParameters.containsKey).firstOrNull;
    if (pk != null) {
      final n = int.tryParse(url.queryParameters[pk]!) ?? 1;
      final next = await rowsFor(_withQuery(url, {pk: '${n + 1}'}));
      if (next != null && next.isNotEmpty && !ids(next).every(first.contains)) {
        pageParam = pk;
        firstPage = n;
      } else if (next != null && next.isEmpty) {
        pageParam = pk; // just one page today
        firstPage = n;
      }
    } else if (ok != null) {
      final start = int.tryParse(url.queryParameters[ok]!) ?? 0;
      final next = await rowsFor(_withQuery(url, {ok: '${start + rows.length}'}));
      if (next != null && !ids(next).every(first.contains)) {
        offsetParam = ok;
        pageSize = rows.length;
      }
    } else {
      // No page number in the address: see whether ?page=2 gives other orders.
      final next = await rowsFor(_withQuery(url, {'page': '2'}));
      if (next != null && next.isNotEmpty && !ids(next).any(first.contains)) {
        pageParam = 'page';
        firstPage = 1;
      }
    }
  }

  final orders = [for (final r in rows) ?mapping.toOrder(r)];
  final oldestFirst = orders.length >= 2 && orders.first.created.isBefore(orders.last.created);
  return OrderList(
    kind: 'json',
    url: url.toString(),
    arrayPath: found.path,
    mapping: mapping,
    pageParam: pageParam,
    firstPage: firstPage,
    offsetParam: offsetParam,
    pageSize: pageSize,
    oldestFirst: oldestFirst,
  );
}

/// A table on a page, as an order list.
OrderList tableList(Uri pageUrl, PageTable t, OrderMapping mapping) =>
    OrderList(kind: 'table', url: pageUrl.toString(), tableSig: t.signature, mapping: mapping);

/// Reads a website's orders through the built-in browser, read-only: it opens
/// the admin page in a hidden browser (so the website's own sign-in is used)
/// and asks for the chosen lists again, page by page.
class BrowserConnector extends StoreConnector {
  final BrowserSource source;
  final PageClient page;
  final DateTime? importFrom;

  /// After the first full read, only orders placed in the last this-many days
  /// are read again (to follow their status).
  final int followDays;

  /// Pages read per list in one go at most.
  final int maxPages;

  /// True when an order is already here, unchanged. Used to stop paging
  /// through a newest-first list whose rows have no date.
  final Future<bool> Function(RemoteOrder o)? unchanged;
  BrowserConnector({
    required this.source,
    required this.page,
    this.importFrom,
    this.followDays = 45,
    this.maxPages = 200,
    this.unchanged,
  });

  final _recent = <Captured>[];
  final _headers = <String, Captured>{};
  final _seen = <String>{};
  StreamSubscription<Captured>? _sub;
  bool _opened = false;
  bool _reopened = false;
  int _list = 0;
  int _page = 0;

  void _onCapture(Captured c) {
    _recent.add(c);
    if (_recent.length > 40) _recent.removeAt(0);
    _headers[listKey(c.url)] = c;
  }

  Future<void> _open() async {
    _sub ??= page.captured.listen(_onCapture);
    _recent.clear();
    _headers.clear();
    await page.open(Uri.parse(source.pageUrl));
    // Give the admin panel a moment to ask for its own lists (with its sign-in).
    final want = {for (final l in source.lists.where((l) => l.kind == 'json')) listKey(Uri.parse(l.url))};
    final until = DateTime.now().add(const Duration(seconds: 15));
    while (want.isNotEmpty && !want.any(_headers.containsKey) && DateTime.now().isBefore(until)) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    _opened = true;
  }

  Future<void> close() async {
    await _sub?.cancel();
    _sub = null;
  }

  DateTime? _cutoff(DateTime? since) {
    final follow = DateTime.now().toUtc().subtract(Duration(days: followDays));
    final from = since == null || since.isBefore(follow) ? since : follow;
    if (importFrom == null) return from;
    if (from == null) return importFrom;
    return from.isAfter(importFrom!) ? from : importFrom;
  }

  @override
  Future<RemotePage<RemoteOrder>> orders({DateTime? since, required int page}) async {
    if (page == 1) {
      _list = 0;
      _page = 0;
      _seen.clear();
      _reopened = false;
      // Table lists open their own page; only API lists need the panel's sign-in.
      if (!_opened && source.lists.any((l) => l.kind == 'json')) await _open();
    }
    if (_list >= source.lists.length) return const RemotePage([], false);
    final l = source.lists[_list];
    final (got, more) = await _read(l, _page, since);
    if (more && _page + 1 < maxPages) {
      _page++;
    } else {
      _list++;
      _page = 0;
    }
    return RemotePage(got, _list < source.lists.length);
  }

  Future<(List<RemoteOrder>, bool)> _read(OrderList l, int i, DateTime? since) async {
    if (l.kind == 'table') return (await _readTable(l), false);
    final url = l.urlForPage(i);
    FetchResult? res;
    if (i == 0) {
      // The admin panel may have just asked for exactly this.
      final mine = _recent.where((c) => c.url == url && c.status == 200).lastOrNull;
      if (mine != null) res = FetchResult(200, 'application/json', mine.body);
    }
    res ??= await _ask(url);
    if ((res.status == 401 || res.status == 403 || (res.ok && res.looksLikeHtml)) && !_reopened) {
      // The website may have renewed its sign-in: open its page again once.
      _reopened = true;
      await _open();
      res = await _ask(url);
    }
    if (res.status == 401 || res.status == 403) throw WebsiteException('signed_out');
    if (res.status == 0) throw WebsiteException('network', res.body.isEmpty ? 'no answer' : res.body);
    if (res.status == 404) throw WebsiteException('not_found', url.path);
    if (!res.ok) throw WebsiteException('network', '${res.status}');
    final json = _decode(res.body);
    if (json == null) throw WebsiteException(res.looksLikeHtml ? 'signed_out' : 'bad_reply');
    final rows = rowsAt(json, l.arrayPath);
    if (rows == null) {
      // {"message": "Not authorized"} and the like.
      final said = json is Map && (json['message'] != null || json['error'] != null || json['msg'] != null);
      throw WebsiteException(said ? 'signed_out' : 'bad_reply');
    }
    final got = [for (final r in rows) ?l.mapping.toOrder(r)];
    if (!l.pageable || got.isEmpty) return (got, false);
    final fresh = got.where((o) => _seen.add(o.id)).length;
    if (fresh == 0) return (const <RemoteOrder>[], false); // the website ignores the page number
    final info = pageInfo(json, l.arrayPath);
    var more = info.more ?? (info.lastPage == null || (l.firstPage + i) < info.lastPage!);
    if (more && !l.oldestFirst) {
      if (l.mapping.has(OrderField.created)) {
        final cutoff = _cutoff(since);
        if (cutoff != null && got.every((o) => o.created.isBefore(cutoff))) more = false;
      } else if (unchanged != null) {
        // No dates: stop at a page where every order is already here, unchanged.
        var all = true;
        for (final o in got) {
          if (!await unchanged!(o)) {
            all = false;
            break;
          }
        }
        if (all) more = false;
      }
    }
    return (got, more);
  }

  Future<FetchResult> _ask(Uri url) {
    // The same list's own request, else any request the panel made to the
    // same website (they all carry the same sign-in).
    final c = _headers[listKey(url)] ?? _recent.where((r) => r.url.host == url.host).lastOrNull;
    return page.get(url, headers: c?.headers ?? const {}, withCredentials: c?.withCredentials ?? false);
  }

  Future<List<RemoteOrder>> _readTable(OrderList l) async {
    await page.open(Uri.parse(l.url));
    // Tables are often filled in a moment after the page loads.
    PageTable? table;
    for (var tries = 0; tries < 12 && table == null; tries++) {
      final ts = await page.tables();
      table = ts.where((t) => t.signature == l.tableSig).firstOrNull;
      if (table == null) await Future<void>.delayed(const Duration(milliseconds: 750));
    }
    if (table == null) throw WebsiteException('signed_out');
    return [for (final r in table.asRows()) ?l.mapping.toOrder(r)];
  }

  @override
  Future<RemotePage<RemoteProduct>> products({DateTime? since, required int page}) async => const RemotePage([], false);

  @override
  Future<String> test() async {
    final pg = await orders(page: 1);
    return pg.more ? '${pg.items.length}+' : '${pg.items.length}';
  }

  @override
  WebStatus mapStatus(RemoteOrder o) => webStatusOf(localStatusOf(o.status));
}

/// A website status (in this app's words) as what it means for the order here.
WebStatus webStatusOf(String? local) => switch (local) {
      null => WebStatus.skip,
      'booked' => WebStatus.shipped,
      'delivered' || 'partial' => WebStatus.delivered,
      'returned' => WebStatus.returned,
      'cancelled' => WebStatus.cancelled,
      _ => WebStatus.open,
    };

/// Orders already in hand (pasted from a table), for bringing them in once.
class ListConnector extends StoreConnector {
  final List<RemoteOrder> list;
  ListConnector(this.list);

  @override
  Future<RemotePage<RemoteOrder>> orders({DateTime? since, required int page}) async =>
      RemotePage(page == 1 ? list : const [], false);

  @override
  Future<RemotePage<RemoteProduct>> products({DateTime? since, required int page}) async => const RemotePage([], false);

  @override
  Future<String> test() async => '${list.length}';

  @override
  WebStatus mapStatus(RemoteOrder o) => webStatusOf(localStatusOf(o.status));
}
