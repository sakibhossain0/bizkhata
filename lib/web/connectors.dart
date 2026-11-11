import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// Thrown when the website can't be reached or refuses the keys.
class WebsiteException implements Exception {
  /// auth | not_found | network | bad_reply | refused
  final String code;
  final String? detail;

  /// For `refused`: the order's status on the website, if it said.
  final String? remoteStatus;
  WebsiteException(this.code, [this.detail, this.remoteStatus]);
  @override
  String toString() => detail == null ? 'web_$code' : 'web_$code:$detail';
}

/// A status change made here, to be copied to the website's order.
class StatusPush {
  /// In the website's words: accepted | shipped | delivered | partial | returned | cancelled.
  final String status;
  final String? courier;
  final String? trackingCode;
  final String? consignmentId;
  const StatusPush(this.status, {this.courier, this.trackingCode, this.consignmentId});

  Map<String, Object?> toJson() => {
        'status': status,
        if (courier != null) 'courier': courier,
        if (trackingCode != null) 'tracking_code': trackingCode,
        if (consignmentId != null) 'consignment_id': consignmentId,
        'source': 'bizkhata',
      };
}

/// An online order's status here, in the order it normally moves.
int orderStatusRank(String status) => switch (status) {
      'pending' => 0,
      'confirmed' => 1,
      'booked' => 2,
      'delivered' || 'partial' || 'returned' || 'cancelled' => 3,
      _ => 0,
    };

/// The word sent to the website for a status reached here (null: nothing to send).
String? pushStatusName(String status) => switch (status) {
      'confirmed' => 'accepted',
      'booked' => 'shipped',
      'delivered' => 'delivered',
      'partial' => 'partial',
      'returned' => 'returned',
      'cancelled' => 'cancelled',
      _ => null,
    };

/// A website status in this app's words (pending, confirmed, booked,
/// delivered, partial, returned, cancelled), or null for drafts.
String? localStatusOf(String remote) {
  final s = remote.toLowerCase().replaceFirst('wc-', '').replaceAll(RegExp(r'[\s-]+'), '_');
  return switch (s) {
    // "processing" stays a waiting order: on WooCommerce and many shops it is
    // simply "new, not yet looked at".
    'accepted' || 'confirmed' || 'in_review' || 'packed' || 'ready_to_ship' || 'approved' || 'verified' => 'confirmed',
    'shipped' || 'dispatched' || 'in_transit' || 'booked' || 'out_for_delivery' || 'picked' || 'picked_up' ||
    'on_the_way' || 'shipping' || 'in_courier' || 'handed_to_courier' || 'sent_to_courier' => 'booked',
    'delivered' || 'completed' || 'complete' => 'delivered',
    'partial' || 'partial_delivered' || 'partially_delivered' || 'partial_delivery' => 'partial',
    'returned' || 'return' || 'rto' || 'returned_to_sender' || 'returned_to_merchant' => 'returned',
    'cancelled' || 'canceled' || 'cancel' || 'failed' || 'refunded' || 'rejected' || 'declined' => 'cancelled',
    'draft' || 'incomplete' || 'abandoned' || 'checkout_draft' || 'trash' || 'deleted' => null,
    _ => 'pending',
  };
}

class RemoteLine {
  /// The website's product (or variation) id, if it has one.
  final String? productId;
  final String? sku;
  final String name;
  final double qty;

  /// Price of one unit before any order-level discount.
  final double price;
  const RemoteLine({this.productId, this.sku, required this.name, required this.qty, required this.price});
}

class RemoteOrder {
  final String id;
  final String number;
  final String status;
  final DateTime created;
  final DateTime updated;
  final String name;
  final String phone;
  final String address;
  final String? area;
  final String? city;
  final String? note;
  final String? payment;
  final String? courier;
  final String? tracking;
  final List<RemoteLine> lines;
  final double shipping;
  final double discount;
  final double total;

  /// Already paid online (bKash, card ...). Cash on delivery is 0.
  final double paid;

  /// Changes whenever the order changes on the website. Websites that give
  /// no "updated" time get a fingerprint of the order instead; null means use
  /// [updated].
  final String? version;
  const RemoteOrder({
    required this.id,
    required this.number,
    required this.status,
    required this.created,
    required this.updated,
    this.version,
    required this.name,
    required this.phone,
    required this.address,
    this.area,
    this.city,
    this.note,
    this.payment,
    this.courier,
    this.tracking,
    required this.lines,
    required this.shipping,
    required this.discount,
    required this.total,
    required this.paid,
  });
}

class RemoteProduct {
  final String id;
  final String? sku;
  final String name;
  final double? price;
  final double? stock;
  final bool tracksStock;
  final DateTime updated;
  const RemoteProduct({
    required this.id,
    this.sku,
    required this.name,
    this.price,
    this.stock,
    this.tracksStock = true,
    required this.updated,
  });
}

class RemotePage<T> {
  final List<T> items;
  final bool more;
  const RemotePage(this.items, this.more);
}

/// What an order's status on the website means for the order here.
enum WebStatus { open, shipped, delivered, returned, cancelled, skip }

/// One online store the app can read orders and products from.
abstract class StoreConnector {
  /// Orders changed after [since], oldest change first.
  Future<RemotePage<RemoteOrder>> orders({DateTime? since, required int page});

  /// Products changed after [since], oldest change first.
  Future<RemotePage<RemoteProduct>> products({DateTime? since, required int page});

  /// A one-line description of the store if the address and keys work.
  Future<String> test();
  WebStatus mapStatus(RemoteOrder o);

  /// The website's status in this app's words, used to tell which side is ahead.
  String? localStatus(RemoteOrder o) => localStatusOf(o.status);

  /// True when status changes made here can be sent back to the website.
  bool get canPush => false;

  /// Move the website's order [extId] along. Returns the website's status
  /// afterwards when it says. Throws [WebsiteException] `refused` when the
  /// website does not allow the change.
  Future<String?> pushStatus(String extId, StatusPush push) => throw UnsupportedError('read-only website');
}

// ----------------------------------------------------------------------- helpers

double _num(Object? v) {
  if (v is num) return v.toDouble();
  if (v is String) return double.tryParse(v.replaceAll(',', '').trim()) ?? 0;
  return 0;
}

double? _numOrNull(Object? v) => v == null || (v is String && v.trim().isEmpty) ? null : _num(v);

String? _str(Object? v) {
  if (v == null) return null;
  final s = '$v'.trim();
  return s.isEmpty ? null : s;
}

/// First non-empty value among [keys] in [j].
Object? _pick(Map j, List<String> keys) {
  for (final k in keys) {
    final v = j[k];
    if (v != null && '$v'.trim().isNotEmpty) return v;
  }
  return null;
}

/// ISO dates with or without a zone; a bare WooCommerce "_gmt" value is UTC.
DateTime _date(Object? v, {bool utc = false}) {
  final s = _str(v);
  if (s == null) return DateTime.now().toUtc();
  final hasZone = RegExp(r'(Z|[+-]\d\d:?\d\d)$').hasMatch(s);
  return (DateTime.tryParse(utc && !hasZone ? '${s}Z' : s) ?? DateTime.now()).toUtc();
}

String _join(Iterable<Object?> parts) => parts.map(_str).whereType<String>().join(', ');

Future<http.Response> _get(http.Client client, Uri url, {Map<String, String>? headers}) async {
  final http.Response res;
  try {
    res = await client.get(url, headers: {'Accept': 'application/json', ...?headers}).timeout(const Duration(seconds: 45));
  } on TimeoutException {
    throw WebsiteException('network', 'no answer');
  } catch (e) {
    throw WebsiteException('network', '$e');
  }
  if (res.statusCode == 401 || res.statusCode == 403) throw WebsiteException('auth', '${res.statusCode}');
  if (res.statusCode == 404) throw WebsiteException('not_found', url.path);
  if (res.statusCode >= 400) throw WebsiteException('network', '${res.statusCode}');
  return res;
}

/// POST a JSON body. A 4xx answer (other than a bad key) means the website
/// understood and said no: that is `refused`, with its message, and is not
/// worth retrying. No answer or a 5xx is `network`, worth retrying later.
Future<http.Response> _postJson(http.Client client, Uri url, Map<String, Object?> body,
    {Map<String, String>? headers}) async {
  final http.Response res;
  try {
    res = await client
        .post(url,
            headers: {'Accept': 'application/json', 'Content-Type': 'application/json', ...?headers},
            body: jsonEncode(body))
        .timeout(const Duration(seconds: 30));
  } on TimeoutException {
    throw WebsiteException('network', 'no answer');
  } catch (e) {
    throw WebsiteException('network', '$e');
  }
  if (res.statusCode == 401 || res.statusCode == 403) throw WebsiteException('auth', '${res.statusCode}');
  if (res.statusCode == 408 || res.statusCode == 429 || res.statusCode >= 500) {
    throw WebsiteException('network', '${res.statusCode}');
  }
  if (res.statusCode >= 400) {
    String? message;
    String? status;
    try {
      final j = jsonDecode(utf8.decode(res.bodyBytes));
      if (j is Map) {
        message = _str(j['message'] ?? j['error']);
        status = _str(j['status']);
      }
    } catch (_) {}
    throw WebsiteException('refused', message ?? (res.statusCode == 404 ? 'no status link (404)' : '${res.statusCode}'), status);
  }
  return res;
}

Object? _json(http.Response res) {
  try {
    return jsonDecode(utf8.decode(res.bodyBytes));
  } catch (_) {
    throw WebsiteException('bad_reply');
  }
}

String _base(String url) {
  var u = url.trim();
  if (!u.startsWith('http://') && !u.startsWith('https://')) u = 'https://$u';
  return u.replaceAll(RegExp(r'/+$'), '');
}

/// `<address>/<path>`, keeping anything the owner put in the address itself
/// (a secret path or a `?key=` query) and adding [query].
Uri _endpoint(String address, String path, [Map<String, String> query = const {}]) {
  final b = Uri.parse(_base(address));
  final basePath = b.path.replaceAll(RegExp(r'/+$'), '');
  final q = {...b.queryParameters, ...query};
  final withPath = b.replace(path: '$basePath/$path');
  return q.isEmpty ? withPath : withPath.replace(queryParameters: q);
}

// ----------------------------------------------------------------------- WooCommerce

/// WooCommerce REST API v3 with a consumer key and secret
/// (WooCommerce → Settings → Advanced → REST API, "Read" access is enough).
class WooConnector extends StoreConnector {
  final String url;
  final String key;
  final String secret;
  final http.Client client;
  WooConnector({required this.url, required this.key, required this.secret, http.Client? client})
      : client = client ?? http.Client();

  Uri _u(String path, Map<String, String> q) => Uri.parse('${_base(url)}/wp-json/wc/v3$path')
      .replace(queryParameters: {...q, 'consumer_key': key.trim(), 'consumer_secret': secret.trim()});

  Map<String, String> _since(DateTime? since) => {
        'orderby': 'modified',
        'order': 'asc',
        'dates_are_gmt': 'true',
        if (since != null) 'modified_after': since.toUtc().toIso8601String().split('.').first,
      };

  bool _more(http.Response res, int page) => page < (int.tryParse(res.headers['x-wp-totalpages'] ?? '') ?? 1);

  @override
  Future<String> test() async {
    final res = await _get(client, _u('/orders', {'per_page': '1'}));
    if (_json(res) is! List) throw WebsiteException('bad_reply');
    return res.headers['x-wp-total'] ?? '?';
  }

  @override
  Future<RemotePage<RemoteOrder>> orders({DateTime? since, required int page}) async {
    final res = await _get(client, _u('/orders', {'per_page': '50', 'page': '$page', ..._since(since)}));
    final list = _json(res);
    if (list is! List) throw WebsiteException('bad_reply');
    return RemotePage([for (final o in list) _order(Map<String, dynamic>.from(o as Map))], _more(res, page));
  }

  RemoteOrder _order(Map<String, dynamic> j) {
    final bill = Map<String, dynamic>.from(j['billing'] as Map? ?? const {});
    final ship = Map<String, dynamic>.from(j['shipping'] as Map? ?? const {});
    final who = _str(_join([ship['first_name'], ship['last_name']])) ?? _join([bill['first_name'], bill['last_name']]);
    final lines = <RemoteLine>[
      for (final raw in j['line_items'] as List? ?? const [])
        () {
          final l = Map<String, dynamic>.from(raw as Map);
          final qty = _num(l['quantity']);
          final variation = _num(l['variation_id']).toInt();
          return RemoteLine(
            productId: variation != 0 ? '$variation' : _str(l['product_id']),
            sku: _str(l['sku']),
            name: _str(l['name']) ?? 'Item',
            qty: qty <= 0 ? 1 : qty,
            price: qty <= 0 ? _num(l['subtotal']) : _num(l['subtotal']) / qty,
          );
        }(),
      for (final raw in j['fee_lines'] as List? ?? const [])
        if (_num((raw as Map)['total']) > 0) RemoteLine(name: _str(raw['name']) ?? 'Fee', qty: 1, price: _num(raw['total'])),
      if (_num(j['total_tax']) > 0) RemoteLine(name: 'VAT / Tax', qty: 1, price: _num(j['total_tax'])),
    ];
    final cod = '${j['payment_method']}' == 'cod';
    final paid = !cod && _str(j['date_paid_gmt'] ?? j['date_paid']) != null;
    return RemoteOrder(
      id: '${j['id']}',
      number: _str(j['number']) ?? '${j['id']}',
      status: '${j['status']}',
      created: _date(j['date_created_gmt'] ?? j['date_created'], utc: j['date_created_gmt'] != null),
      updated: _date(j['date_modified_gmt'] ?? j['date_modified'], utc: j['date_modified_gmt'] != null),
      name: who,
      phone: _str(ship['phone']) ?? _str(bill['phone']) ?? '',
      address: _join([ship['address_1'] ?? bill['address_1'], ship['address_2'] ?? bill['address_2']]),
      area: _str(ship['state']) ?? _str(bill['state']),
      city: _str(ship['city']) ?? _str(bill['city']),
      note: _str(j['customer_note']),
      payment: _str(j['payment_method_title']),
      lines: lines,
      shipping: _num(j['shipping_total']),
      discount: _num(j['discount_total']),
      total: _num(j['total']),
      paid: paid ? _num(j['total']) : 0,
    );
  }

  @override
  Future<RemotePage<RemoteProduct>> products({DateTime? since, required int page}) async {
    final res = await _get(client, _u('/products', {'per_page': '100', 'page': '$page', ..._since(since)}));
    final list = _json(res);
    if (list is! List) throw WebsiteException('bad_reply');
    final out = <RemoteProduct>[];
    for (final raw in list) {
      final p = Map<String, dynamic>.from(raw as Map);
      if (p['type'] == 'variable') {
        // Each size/colour is its own product here, named after its options.
        final v = await _get(client, _u('/products/${p['id']}/variations', {'per_page': '100'}));
        for (final rawV in _json(v) as List? ?? const []) {
          final x = Map<String, dynamic>.from(rawV as Map);
          final options = [for (final a in x['attributes'] as List? ?? const []) _str((a as Map)['option'])].whereType<String>();
          final parent = _str(p['name']) ?? 'Product';
          out.add(_product(x, name: options.isEmpty ? parent : '$parent - ${options.join(' / ')}'));
        }
      } else {
        out.add(_product(p));
      }
    }
    return RemotePage(out, _more(res, page));
  }

  RemoteProduct _product(Map<String, dynamic> j, {String? name}) => RemoteProduct(
        id: '${j['id']}',
        sku: _str(j['sku']),
        name: name ?? _str(j['name']) ?? 'Product',
        price: _numOrNull(j['price']) ?? _numOrNull(j['regular_price']),
        stock: _numOrNull(j['stock_quantity']),
        tracksStock: j['manage_stock'] == true,
        updated: _date(j['date_modified_gmt'] ?? j['date_modified'], utc: j['date_modified_gmt'] != null),
      );

  /// WooCommerce has no "accepted": every live order is a waiting one here.
  @override
  String? localStatus(RemoteOrder o) => switch (mapStatus(o)) {
        WebStatus.open => 'pending',
        WebStatus.shipped => 'booked',
        WebStatus.delivered => 'delivered',
        WebStatus.returned => 'returned',
        WebStatus.cancelled => 'cancelled',
        WebStatus.skip => null,
      };

  @override
  WebStatus mapStatus(RemoteOrder o) {
    final s = o.status.toLowerCase().replaceFirst('wc-', '');
    return switch (s) {
      // "Pending payment": an online payment that never finished. Cash on
      // delivery orders go straight to "processing".
      'pending' => WebStatus.skip,
      'processing' || 'on-hold' => WebStatus.open,
      'completed' || 'delivered' => WebStatus.delivered,
      'shipped' || 'dispatched' || 'in-transit' || 'out-for-delivery' => WebStatus.shipped,
      'returned' => WebStatus.returned,
      'cancelled' || 'failed' || 'refunded' => WebStatus.cancelled,
      'checkout-draft' || 'trash' || 'draft' => WebStatus.skip,
      _ => WebStatus.open,
    };
  }
}

// ----------------------------------------------------------------------- BizKhata JSON API

/// A store's own API in the simple format described in docs/website-api.md:
/// `GET <url>/orders?since=..&page=..`, `GET <url>/products?since=..&page=..`
/// and `POST <url>/orders/<id>/status`.
///
/// The key is optional: a website can instead hand out an address with a long
/// secret in it (`https://api.shop.com/bizkhata/<secret>`). When there is a
/// key it goes in `Authorization: Bearer <key>`.
class JsonApiConnector extends StoreConnector {
  final String url;
  final String key;
  final http.Client client;
  JsonApiConnector({required this.url, this.key = '', http.Client? client}) : client = client ?? http.Client();

  Map<String, String> get _auth => key.trim().isEmpty ? const {} : {'Authorization': 'Bearer ${key.trim()}'};

  Future<(List, bool)> _page(String path, DateTime? since, int page) async {
    final res = await _get(
      client,
      _endpoint(url, path, {
        'page': '$page',
        if (since != null) 'since': since.toUtc().toIso8601String(),
      }),
      headers: _auth,
    );
    final j = _json(res);
    if (j is List) return (j, false);
    if (j is Map) {
      final list = j[path] ?? j['data'] ?? j['items'];
      if (list is List) {
        final next = j['next_page'] ?? j['nextPage'];
        final more = next != null && next != false && '$next' != '0' && '$next'.isNotEmpty;
        return (list, more);
      }
    }
    throw WebsiteException('bad_reply');
  }

  @override
  Future<String> test() async {
    final (list, more) = await _page('orders', null, 1);
    return more ? '${list.length}+' : '${list.length}';
  }

  @override
  Future<RemotePage<RemoteOrder>> orders({DateTime? since, required int page}) async {
    final (list, more) = await _page('orders', since, page);
    return RemotePage([for (final o in list) parseOrder(Map<String, dynamic>.from(o as Map))], more);
  }

  /// Lenient: accepts the documented names and a few common alternatives.
  static RemoteOrder parseOrder(Map<String, dynamic> j) {
    final c = Map<String, dynamic>.from((j['customer'] ?? j['shipping'] ?? const {}) as Map);
    Object? field(List<String> keys) => _pick(c, keys) ?? _pick(j, keys);
    final created = _pick(j, ['created_at', 'createdAt', 'date', 'created']);
    return RemoteOrder(
      id: '${_pick(j, ['id', '_id']) ?? ''}',
      number: _str(_pick(j, ['number', 'invoice', 'invoice_no', 'invoiceNo', 'order_number'])) ?? '${j['id'] ?? j['_id']}',
      status: _str(_pick(j, ['status', 'order_status'])) ?? 'pending',
      created: _date(created),
      updated: _date(_pick(j, ['updated_at', 'updatedAt', 'modified', 'updated']) ?? created),
      name: _str(field(['name', 'customer_name', 'fullName', 'full_name'])) ?? '',
      phone: _str(field(['phone', 'mobile', 'customer_phone'])) ?? '',
      address: _str(field(['address', 'shipping_address', 'customer_address'])) ?? '',
      area: _str(field(['area', 'zone', 'thana'])),
      city: _str(field(['city', 'district'])),
      note: _str(_pick(j, ['note', 'notes', 'customer_note'])),
      payment: _str(_pick(j, ['payment_method', 'paymentMethod'])),
      courier: _str(_pick(j, ['courier'])),
      tracking: _str(_pick(j, ['tracking_code', 'tracking', 'consignment_id', 'trackingCode'])),
      lines: [
        for (final raw in (_pick(j, ['items', 'lines', 'products', 'order_items']) as List?) ?? const [])
          () {
            final l = Map<String, dynamic>.from(raw as Map);
            final qty = _num(_pick(l, ['qty', 'quantity']));
            return RemoteLine(
              productId: _str(_pick(l, ['product_id', 'productId', 'id', '_id'])),
              sku: _str(_pick(l, ['sku', 'code'])),
              name: _str(_pick(l, ['name', 'title', 'product_name'])) ?? 'Item',
              qty: qty <= 0 ? 1 : qty,
              price: _num(_pick(l, ['price', 'unit_price', 'unitPrice'])),
            );
          }(),
      ],
      shipping: _num(_pick(j, ['shipping', 'shipping_charge', 'delivery_charge', 'deliveryCharge'])),
      discount: _num(_pick(j, ['discount', 'discount_total'])),
      total: _num(_pick(j, ['total', 'grand_total', 'grandTotal'])),
      paid: _num(_pick(j, ['paid', 'advance', 'paid_amount'])),
    );
  }

  @override
  Future<RemotePage<RemoteProduct>> products({DateTime? since, required int page}) async {
    final (list, more) = await _page('products', since, page);
    return RemotePage([
      for (final raw in list)
        () {
          final p = Map<String, dynamic>.from(raw as Map);
          final stock = _numOrNull(_pick(p, ['stock', 'quantity', 'stock_quantity']));
          return RemoteProduct(
            id: '${_pick(p, ['id', '_id']) ?? ''}',
            sku: _str(_pick(p, ['sku', 'code'])),
            name: _str(_pick(p, ['name', 'title'])) ?? 'Product',
            price: _numOrNull(_pick(p, ['price', 'sale_price', 'salePrice'])),
            stock: stock,
            tracksStock: p['manage_stock'] != false && stock != null,
            updated: _date(_pick(p, ['updated_at', 'updatedAt', 'modified'])),
          );
        }(),
    ], more);
  }

  @override
  WebStatus mapStatus(RemoteOrder o) {
    final s = o.status.toLowerCase().replaceAll(RegExp(r'[\s-]+'), '_');
    return switch (s) {
      'shipped' || 'dispatched' || 'in_transit' || 'booked' || 'out_for_delivery' => WebStatus.shipped,
      'delivered' || 'completed' || 'partial' || 'partial_delivered' => WebStatus.delivered,
      'returned' => WebStatus.returned,
      'cancelled' || 'canceled' || 'failed' || 'refunded' => WebStatus.cancelled,
      'draft' || 'incomplete' || 'abandoned' => WebStatus.skip,
      _ => WebStatus.open,
    };
  }

  @override
  bool get canPush => true;

  @override
  Future<String?> pushStatus(String extId, StatusPush push) async {
    final res = await _postJson(client, _endpoint(url, 'orders/${Uri.encodeComponent(extId)}/status'), push.toJson(),
        headers: _auth);
    try {
      final j = jsonDecode(utf8.decode(res.bodyBytes));
      if (j is Map) return _str(j['status'] ?? (j['order'] is Map ? (j['order'] as Map)['status'] : null));
    } catch (_) {
      // An empty 200/204 is fine too.
    }
    return null;
  }
}
