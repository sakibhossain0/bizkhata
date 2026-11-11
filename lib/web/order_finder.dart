import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:intl/intl.dart';

import 'connectors.dart';

/// Recognises lists of orders in whatever a website's admin panel loads (JSON
/// from its own API, an HTML table, or rows pasted from a spreadsheet) and
/// turns their rows into [RemoteOrder]s.
///
/// Nothing here knows any particular website. Each detail (phone, total,
/// status ...) is found by the names websites commonly give it, by where it
/// sits (a phone under "shipping" beats one under "admin") and by what the
/// values look like (a phone has 8-15 digits, a total is a number).

/// The order details BizKhata can take from a website's list.
enum OrderField {
  id,
  number,
  status,
  created,
  updated,
  name,
  phone,
  address,
  area,
  city,
  note,
  payment,
  paymentStatus,
  courier,
  tracking,
  total,
  shipping,
  discount,
  paid,
}

/// The details of one item line inside an order.
enum ItemField { name, qty, price, lineTotal, sku, productId }

/// Where each detail sits inside one row of a website's order list. Paths
/// use dots for nesting (`shipping.phone`) and `+` to join several values
/// (`first_name+last_name`).
class OrderMapping {
  final Map<OrderField, String> fields;

  /// The path of the items array inside a row, if the rows have items.
  final String? items;
  final Map<ItemField, String> itemFields;

  const OrderMapping({this.fields = const {}, this.items, this.itemFields = const {}});

  bool has(OrderField f) => fields.containsKey(f);

  OrderMapping withField(OrderField f, String? path) {
    final next = {...fields};
    if (path == null || path.isEmpty) {
      next.remove(f);
    } else {
      next[f] = path;
    }
    return OrderMapping(fields: next, items: items, itemFields: itemFields);
  }

  OrderMapping withoutItems() => OrderMapping(fields: fields);

  Map<String, Object?> toJson() => {
        'fields': {for (final e in fields.entries) e.key.name: e.value},
        'items': ?items,
        if (itemFields.isNotEmpty) 'itemFields': {for (final e in itemFields.entries) e.key.name: e.value},
      };

  factory OrderMapping.fromJson(Map<String, dynamic> j) {
    final f = <OrderField, String>{};
    for (final e in (j['fields'] as Map? ?? const {}).entries) {
      final field = OrderField.values.where((v) => v.name == e.key).firstOrNull;
      if (field != null && e.value is String) f[field] = e.value as String;
    }
    final it = <ItemField, String>{};
    for (final e in (j['itemFields'] as Map? ?? const {}).entries) {
      final field = ItemField.values.where((v) => v.name == e.key).firstOrNull;
      if (field != null && e.value is String) it[field] = e.value as String;
    }
    return OrderMapping(fields: f, items: j['items'] as String?, itemFields: it);
  }

  /// One row as an order, or null when the row has nothing to go by.
  RemoteOrder? toOrder(Map row) {
    String? text(OrderField f) => _text(valueAt(row, fields[f], joiner: f == OrderField.address ? ', ' : ' '));
    final number = text(OrderField.number);
    final created = _when(valueAt(row, fields[OrderField.created]));
    final updatedRaw = valueAt(row, fields[OrderField.updated]);
    final updated = _when(updatedRaw);
    final phone = text(OrderField.phone) ?? '';
    final lines = _lines(row);
    final shipping = _money(valueAt(row, fields[OrderField.shipping])) ?? 0;
    final discount = (_money(valueAt(row, fields[OrderField.discount])) ?? 0).abs();
    var total = _money(valueAt(row, fields[OrderField.total]));
    if ((total == null || total == 0) && lines.isNotEmpty) {
      total = lines.fold<double>(0, (s, l) => s + l.qty * l.price) + shipping - discount;
    }
    total ??= 0;
    var paid = _money(valueAt(row, fields[OrderField.paid])) ?? 0;
    if (paid == 0 && _isPaid(valueAt(row, fields[OrderField.paymentStatus]))) paid = total;
    final status = text(OrderField.status) ?? 'pending';
    final tracking = text(OrderField.tracking);
    final courier = text(OrderField.courier);
    var id = text(OrderField.id) ?? number;
    if (id == null) {
      // No id at all (a pasted sheet without an order number): the same row
      // must always give the same id, so pasting twice brings nothing twice.
      final key = [phone, _text(valueAt(row, fields[OrderField.created])), total].join('|');
      if (phone.isEmpty && created == null) return null;
      id = 'row-${sha1.convert(utf8.encode(key)).toString().substring(0, 16)}';
    }
    final when = created ?? DateTime.now().toUtc();
    // Changes whenever the order changes on the website, so an unchanged order
    // is skipped quickly and a changed one is looked at again.
    final version = _text(updatedRaw) ??
        sha1
            .convert(utf8.encode(jsonEncode([status, total, tracking, courier, shipping, discount, paid, lines.length])))
            .toString()
            .substring(0, 16);
    return RemoteOrder(
      id: id,
      number: number ?? id,
      status: status,
      created: when,
      updated: updated ?? when,
      version: version,
      name: text(OrderField.name) ?? '',
      phone: phone,
      address: text(OrderField.address) ?? '',
      area: text(OrderField.area),
      city: text(OrderField.city),
      note: text(OrderField.note),
      payment: text(OrderField.payment),
      courier: courier,
      tracking: tracking,
      lines: lines,
      shipping: shipping,
      discount: discount,
      total: total,
      paid: paid,
    );
  }

  List<RemoteLine> _lines(Map row) {
    final raw = valueAt(row, items);
    if (raw is! List) return const [];
    final out = <RemoteLine>[];
    for (final it in raw) {
      if (it is! Map) continue;
      String? t(ItemField f) => _text(valueAt(it, itemFields[f]));
      final name = t(ItemField.name);
      if (name == null) continue;
      final qtyRaw = _money(valueAt(it, itemFields[ItemField.qty]));
      final qty = qtyRaw == null || qtyRaw <= 0 ? 1.0 : qtyRaw;
      var price = _money(valueAt(it, itemFields[ItemField.price]));
      final lineTotal = _money(valueAt(it, itemFields[ItemField.lineTotal]));
      if ((price == null || price == 0) && lineTotal != null) price = lineTotal / qty;
      final options = _options(it);
      out.add(RemoteLine(
        productId: t(ItemField.productId),
        sku: t(ItemField.sku),
        name: options.isEmpty ? name : '$name (${options.join(', ')})',
        qty: qty,
        price: price ?? 0,
      ));
    }
    return out;
  }
}

/// The value at [path] in [row]: `a.b.c` for nesting, `a+b` to join values.
Object? valueAt(Object? row, String? path, {String joiner = ' '}) {
  if (row == null || path == null || path.isEmpty) return null;
  if (path.contains('+')) {
    final parts = [for (final p in path.split('+')) _text(valueAt(row, p))].whereType<String>().toList();
    return parts.isEmpty ? null : parts.join(joiner);
  }
  Object? cur = row;
  for (final seg in path.split('.')) {
    if (cur is Map) {
      cur = cur[seg];
    } else if (cur is List) {
      final i = int.tryParse(seg);
      cur = i != null && i >= 0 && i < cur.length ? cur[i] : null;
    } else {
      return null;
    }
    if (cur == null) return null;
  }
  // Mongo's extended JSON: {"$date": "..."} / {"$oid": "..."}.
  if (cur is Map && cur.length == 1) {
    final v = cur[r'$date'] ?? cur[r'$oid'] ?? cur[r'$numberLong'] ?? cur[r'$numberDecimal'];
    if (v != null) return v is Map ? v.values.firstOrNull : v;
  }
  return cur;
}

/// The list of rows at [path] in [json] ('' = the json itself).
List<Map<String, dynamic>>? rowsAt(Object? json, String path) {
  final v = path.isEmpty ? json : valueAt(json, path);
  if (v is! List) return null;
  return [
    for (final e in v)
      if (e is Map) Map<String, dynamic>.from(e),
  ];
}

// ----------------------------------------------------------------- finding

/// A list of orders found in a website's data.
class FoundList {
  /// Where the list sits in the JSON ('' = the JSON is the list).
  final String path;
  final List<Map<String, dynamic>> rows;
  final OrderMapping mapping;
  final double score;
  const FoundList(this.path, this.rows, this.mapping, this.score);

  List<RemoteOrder> orders() => [
        for (final r in rows) ?mapping.toOrder(r),
      ];

  /// Every field path in the rows with an example value, for choosing by hand.
  List<(String, String)> choices() => fieldChoices(rows);
}

/// Every list of orders in [json], best first.
List<FoundList> findOrderLists(Object? json) {
  final found = <FoundList>[];
  void walk(Object? v, String path, int depth) {
    if (depth > 5) return;
    if (v is List) {
      final maps = v.whereType<Map>().length;
      if (maps > 0 && maps >= v.length * 0.8) {
        final rows = [for (final e in v.whereType<Map>()) Map<String, dynamic>.from(e)];
        final hit = judgeRows(rows, path: path);
        if (hit != null) {
          found.add(hit);
          return; // the rows' own arrays (items) are not separate order lists
        }
        // A list of wrappers: look inside the first few for nested lists.
        for (final e in v.take(1)) {
          walk(e, path, depth + 1);
        }
      }
      return;
    }
    if (v is Map) {
      for (final e in v.entries) {
        final k = '${e.key}';
        if (k.contains('.') || k.contains('+')) continue;
        walk(e.value, path.isEmpty ? k : '$path.$k', depth + 1);
      }
    }
  }

  walk(json, '', 0);
  found.sort((a, b) {
    final s = b.score.compareTo(a.score);
    return s != 0 ? s : b.rows.length.compareTo(a.rows.length);
  });
  return found;
}

/// The rows as an order list (with their mapping), or null if they don't
/// look like orders.
FoundList? judgeRows(List<Map<String, dynamic>> rows, {String path = '', OrderMapping? mapping}) {
  if (rows.isEmpty) return null;
  final m = mapping ?? autoMap(rows);
  final s = orderScore(m);
  if (mapping == null && !looksLikeOrders(m, s)) return null;
  return FoundList(path, rows, m, s);
}

/// How much a mapping looks like an order list (0 to ~13).
double orderScore(OrderMapping m) {
  var s = 0.0;
  if (m.has(OrderField.phone)) s += 3;
  if (m.has(OrderField.total)) s += 2;
  if (m.items != null) s += 2;
  if (m.has(OrderField.status)) s += 1.5;
  if (m.has(OrderField.id) || m.has(OrderField.number)) s += 1.5;
  if (m.has(OrderField.created)) s += 1;
  if (m.has(OrderField.name)) s += 1;
  if (m.has(OrderField.address)) s += 1;
  return s;
}

/// Orders need something to tell them apart, an amount or items, and a
/// customer. Product, customer and sales-by-day lists fail one of these.
bool looksLikeOrders(OrderMapping m, double score) =>
    (m.has(OrderField.id) || m.has(OrderField.number)) &&
    (m.has(OrderField.total) || m.items != null) &&
    (m.has(OrderField.phone) || m.has(OrderField.address) || (m.has(OrderField.name) && m.has(OrderField.total))) &&
    score >= 6;

// Names websites give each detail, already normalised (see _norm), best first.
const _names = <OrderField, List<String>>{
  OrderField.id: ['id', 'orderid', 'uuid', 'oid', 'key'],
  OrderField.number: [
    // Not "no", "sl" or "serial": in tables those are row counters that
    // start again on every page.
    'invoiceno', 'invoicenumber', 'invoice', 'invoiceid', 'ordernumber', 'orderno', 'ordercode', 'orderref',
    'number', 'code', 'reference', 'ref', 'ইনভয়েস', 'অর্ডারনং', 'অর্ডারনম্বর',
  ],
  OrderField.status: [
    'status', 'orderstatus', 'state', 'currentstatus', 'orderstate', 'stage', 'deliverystatus',
    'fulfillmentstatus', 'অবস্থা', 'স্ট্যাটাস',
  ],
  OrderField.created: [
    'createdat', 'created', 'orderdate', 'date', 'placedat', 'createdon', 'datecreated', 'createddate',
    'orderedat', 'ordertime', 'orderat', 'time', 'timestamp', 'datecreatedgmt', 'তারিখ',
  ],
  OrderField.updated: [
    'updatedat', 'updated', 'modifiedat', 'modified', 'datemodified', 'lastupdated', 'updatedon',
    'lastmodified', 'updateddate', 'datemodifiedgmt',
  ],
  OrderField.name: [
    'fullname', 'name', 'customername', 'receivername', 'recipientname', 'shippingname', 'billingname',
    'contactname', 'clientname', 'buyername', 'consigneename', 'customer', 'firstname', 'নাম', 'কাস্টমার',
  ],
  OrderField.phone: [
    'phone', 'mobile', 'phonenumber', 'mobilenumber', 'customerphone', 'customermobile', 'contactnumber',
    'contactno', 'contact', 'receiverphone', 'recipientphone', 'consigneephone', 'cell', 'msisdn',
    'phoneno', 'mobileno', 'billingphone', 'shippingphone', 'whatsapp', 'ফোন', 'মোবাইল',
  ],
  OrderField.address: [
    'address', 'fulladdress', 'shippingaddress', 'deliveryaddress', 'address1', 'addressline1', 'street',
    'streetaddress', 'customeraddress', 'billingaddress', 'consigneeaddress', 'location', 'ঠিকানা',
  ],
  OrderField.area: ['thana', 'area', 'upazila', 'upazilla', 'zone', 'policestation', 'subdistrict', 'থানা', 'এলাকা'],
  OrderField.city: ['city', 'district', 'zilla', 'zila', 'town', 'division', 'জেলা', 'শহর'],
  OrderField.note: [
    'note', 'notes', 'customernote', 'ordernote', 'remarks', 'remark', 'comment', 'comments', 'instruction',
    'instructions', 'specialinstruction', 'নোট',
  ],
  OrderField.payment: [
    'paymentmethod', 'paymenttype', 'paymentgateway', 'payment', 'paymentmethodtitle', 'paymentoption',
    'paidby', 'gateway', 'paymentmode', 'পেমেন্ট',
  ],
  OrderField.paymentStatus: ['paymentstatus', 'financialstatus', 'ispaid', 'paidstatus', 'paystatus'],
  OrderField.courier: [
    'courier', 'couriername', 'courierprovider', 'courierservice', 'courierpartner', 'deliverypartner',
    'shippingprovider', 'carrier', 'provider', 'কুরিয়ার',
  ],
  OrderField.tracking: [
    'trackingcode', 'trackingid', 'trackingnumber', 'trackingno', 'tracking', 'consignmentid', 'consignmentno',
    'awb', 'awbno', 'parcelid', 'trackingcodeno',
  ],
  OrderField.total: [
    'total', 'grandtotal', 'totalamount', 'ordertotal', 'totalprice', 'nettotal', 'netamount', 'payable',
    'totalpayable', 'payableamount', 'finaltotal', 'finalamount', 'amount', 'totalbill', 'bill', 'billamount',
    'codamount', 'cod', 'collectableamount', 'collectamount', 'মোট', 'টাকা', 'মোটটাকা',
  ],
  OrderField.shipping: [
    'deliveryfee', 'deliverycharge', 'shippingcharge', 'shippingfee', 'shippingcost', 'deliverycost',
    'shipping', 'shippingtotal', 'delivery', 'courierfee', 'couriercharge', 'deliveryamount', 'ডেলিভারিচার্জ',
  ],
  OrderField.discount: ['discount', 'discountamount', 'discounttotal', 'coupondiscount', 'totaldiscount', 'ছাড়'],
  OrderField.paid: ['paidamount', 'amountpaid', 'advance', 'advanceamount', 'advancepaid', 'paid', 'totalpaid', 'prepaid'],
};

// A word inside a longer name, for names like "customer_phone_number".
const _tokens = <OrderField, List<String>>{
  OrderField.phone: ['phone', 'mobile', 'msisdn'],
  OrderField.total: ['grandtotal', 'totalamount', 'payable'],
  OrderField.status: ['orderstatus'],
  OrderField.number: ['invoice', 'orderno', 'ordernumber'],
  OrderField.tracking: ['tracking', 'consignment'],
  OrderField.address: ['address'],
  OrderField.created: ['createdat', 'orderdate'],
};

// Where a value sits says a lot: these words in its parents.
const _contactGood = ['shipping', 'delivery', 'receiver', 'recipient', 'consignee', 'deliver'];
const _contactOk = ['customer', 'buyer', 'billing', 'client', 'contact', 'address', 'info', 'details', 'user', 'doc', 'order'];
const _foreign = [
  'product', 'item', 'variant', 'category', 'seller', 'vendor', 'merchant', 'store', 'shop', 'admin', 'author',
  'createdby', 'updatedby', 'staff', 'rider', 'agent', 'courier', 'steadfast', 'pathao', 'redx', 'paperfly',
  'ecourier', 'parcel', 'fraud', 'dispatch', 'booked', 'replaced', 'history', 'log', 'event', 'note', 'sync',
  'payment', 'transaction', 'coupon', 'meta', 'seo', 'image', 'media',
];
const _moneyBad = [
  'item', 'product', 'line', 'variant', 'courier', 'steadfast', 'pathao', 'redx', 'parcel', 'booked', 'replaced',
  'fraud', 'dispatch', 'coupon', 'refund', 'history', 'log', 'event',
];
const _moneyGood = ['summary', 'totals', 'amount', 'pricing', 'price', 'order', 'invoice', 'bill', 'doc'];
const _statusBad = [
  'payment', 'courier', 'steadfast', 'pathao', 'redx', 'parcel', 'fraud', 'dispatch', 'sync', 'booked', 'history',
  'log', 'event', 'customer', 'user', 'product',
];
const _shipBits = ['courier', 'steadfast', 'pathao', 'redx', 'paperfly', 'ecourier', 'parcel', 'shipment', 'consignment', 'delivery', 'shipping', 'tracking'];

// Detail names that mean something else even though they contain a good word.
const _nameBad = ['author', 'admin', 'staff', 'product', 'item', 'file', 'image', 'username', 'user', 'category', 'brand', 'shop', 'store', 'seller', 'vendor', 'courier', 'rider', 'by'];

String _norm(String k) => k.toLowerCase().replaceAll(RegExp(r'''[\s_\-\.\(\)\[\]/:#৳$%,'"*]+'''), '');

/// Each field path in [rows] (up to 4 levels deep) → its values, one per row
/// (null where a row lacks it). Arrays are left out.
Map<String, List<Object?>> _columns(List<Map<String, dynamic>> rows) {
  final cols = <String, List<Object?>>{};
  for (var i = 0; i < rows.length; i++) {
    void add(Map m, String prefix, int depth) {
      for (final e in m.entries) {
        final k = '${e.key}';
        if (k.contains('.') || k.contains('+')) continue;
        final path = prefix.isEmpty ? k : '$prefix.$k';
        var v = e.value;
        if (v is Map && v.length == 1 && (v.containsKey(r'$date') || v.containsKey(r'$oid'))) v = valueAt(m, k);
        if (v is Map) {
          if (depth < 3) add(v, path, depth + 1);
        } else if (v is! List) {
          (cols[path] ??= List<Object?>.filled(rows.length, null))[i] = v;
        }
      }
    }

    add(rows[i], '', 0);
  }
  return cols;
}

/// Array fields in the rows (up to 2 levels deep) → their values per row.
Map<String, List<List?>> _arrays(List<Map<String, dynamic>> rows) {
  final out = <String, List<List?>>{};
  for (var i = 0; i < rows.length; i++) {
    void add(Map m, String prefix, int depth) {
      for (final e in m.entries) {
        final k = '${e.key}';
        if (k.contains('.') || k.contains('+')) continue;
        final path = prefix.isEmpty ? k : '$prefix.$k';
        final v = e.value;
        if (v is List) {
          (out[path] ??= List<List?>.filled(rows.length, null))[i] = v;
        } else if (v is Map && depth < 1) {
          add(v, path, depth + 1);
        }
      }
    }

    add(rows[i], '', 0);
  }
  return out;
}

/// Field paths with an example value, for a "which field is this?" picker.
List<(String, String)> fieldChoices(List<Map<String, dynamic>> rows) {
  final sample = rows.take(25).toList();
  final cols = _columns(sample);
  final out = <(String, String)>[];
  for (final e in cols.entries) {
    final example = e.value.map(_text).whereType<String>().firstOrNull;
    if (example != null) out.add((e.key, example.length > 40 ? '${example.substring(0, 40)}…' : example));
  }
  out.sort((a, b) => a.$1.split('.').length != b.$1.split('.').length
      ? a.$1.split('.').length.compareTo(b.$1.split('.').length)
      : a.$1.compareTo(b.$1));
  return out;
}

/// Works out which field of the rows holds which order detail.
OrderMapping autoMap(List<Map<String, dynamic>> rows) {
  final sample = rows.take(25).toList();
  final cols = _columns(sample);
  final used = <String>{};
  final fields = <OrderField, String>{};

  // The most telling details first, so they get first pick of the fields.
  const order = [
    OrderField.id, OrderField.number, OrderField.phone, OrderField.total, OrderField.status, OrderField.created,
    OrderField.name, OrderField.address, OrderField.city, OrderField.area, OrderField.shipping, OrderField.discount,
    OrderField.paid, OrderField.updated, OrderField.tracking, OrderField.courier, OrderField.payment,
    OrderField.paymentStatus, OrderField.note,
  ];
  for (final f in order) {
    String? best;
    var bestScore = 0.0;
    for (final e in cols.entries) {
      if (used.contains(e.key)) continue;
      final s = _fieldScore(f, e.key, e.value);
      if (s > bestScore) {
        bestScore = s;
        best = e.key;
      }
    }
    if (best == null) continue;
    used.add(best);
    fields[f] = best;
  }

  // A phone nobody named "phone": any column that is mostly phone numbers.
  if (!fields.containsKey(OrderField.phone)) {
    for (final e in cols.entries) {
      if (used.contains(e.key)) continue;
      if (_share(e.value, _isBdPhone) >= 0.6) {
        fields[OrderField.phone] = e.key;
        used.add(e.key);
        break;
      }
    }
  }

  // "#1001"-style names are order numbers (Shopify calls the number "name").
  if (!fields.containsKey(OrderField.number)) {
    for (final e in cols.entries) {
      if (used.contains(e.key) || e.key.contains('.')) continue;
      if (_norm(e.key) == 'name' && _share(e.value, (v) => RegExp(r'^#\s*\w*\d+$').hasMatch('$v'.trim())) >= 0.8) {
        fields[OrderField.number] = e.key;
        used.add(e.key);
      }
    }
  }

  // First and last name kept apart: join them.
  final name = fields[OrderField.name];
  if (name != null && _norm(name.split('.').last) == 'firstname') {
    final prefix = name.contains('.') ? name.substring(0, name.lastIndexOf('.') + 1) : '';
    final last = cols.keys.where((k) => k.startsWith(prefix) && _norm(k.substring(prefix.length)) == 'lastname').firstOrNull;
    if (last != null) fields[OrderField.name] = '$name+$last';
  }
  // Two address lines: join them.
  final addr = fields[OrderField.address];
  if (addr != null && _norm(addr.split('.').last) == 'address1') {
    final prefix = addr.contains('.') ? addr.substring(0, addr.lastIndexOf('.') + 1) : '';
    final second = cols.keys.where((k) => k.startsWith(prefix) && _norm(k.substring(prefix.length)) == 'address2').firstOrNull;
    if (second != null) fields[OrderField.address] = '$addr+$second';
  }

  // The id and the order number are often the same single field.
  if (!fields.containsKey(OrderField.id) && fields.containsKey(OrderField.number)) {
    fields[OrderField.id] = fields[OrderField.number]!;
  }

  final (items, itemFields) = _itemsMapping(sample);
  return OrderMapping(fields: fields, items: items, itemFields: itemFields);
}

double _fieldScore(OrderField f, String path, List<Object?> values) {
  final segs = path.split('.');
  final leaf = _norm(segs.last);
  final parents = [for (final s in segs.take(segs.length - 1)) _norm(s)];
  final full = segs.map(_norm).join();
  final names = _names[f]!;

  var base = 0.0;
  for (var i = 0; i < names.length; i++) {
    if (leaf == names[i] || (parents.isNotEmpty && full == names[i])) {
      base = 100.0 - i;
      break;
    }
  }
  if (base == 0) {
    for (final t in _tokens[f] ?? const <String>[]) {
      if (leaf.contains(t)) {
        base = 40;
        break;
      }
    }
  }
  if (base == 0) return 0;

  bool parentHas(List<String> words) => parents.any((p) => words.any(p.contains));
  var ctx = -3.0 * parents.length;
  switch (f) {
    case OrderField.name || OrderField.phone || OrderField.address || OrderField.area || OrderField.city:
      if (parentHas(_foreign)) ctx -= 60;
      if (parentHas(_contactGood)) {
        ctx += 15;
      } else if (parentHas(_contactOk)) {
        ctx += 8;
      }
      if (f == OrderField.name && _nameBad.any(leaf.contains) && leaf != 'name') return 0;
    case OrderField.total || OrderField.shipping || OrderField.discount || OrderField.paid:
      if (parentHas(_moneyBad)) ctx -= 60;
      if (parentHas(_moneyGood)) ctx += 5;
    case OrderField.status:
      if (parentHas(_statusBad)) ctx -= 40;
    case OrderField.tracking || OrderField.courier:
      if (parentHas(_shipBits)) ctx += 10;
      // A bare "provider" or "code" only counts under a courier-ish parent.
      if ((leaf == 'provider' || leaf == 'code') && !parentHas(_shipBits)) return 0;
    case OrderField.created || OrderField.updated:
      if (parents.isNotEmpty && !parents.every((p) => p == 'doc' || p == 'order' || p == 'dates' || p == 'attributes')) ctx -= 30;
    case OrderField.id || OrderField.number:
      if (parents.isNotEmpty && !parents.every((p) => p == 'doc' || p == 'order' || p == 'attributes')) ctx -= 50;
    case OrderField.note || OrderField.payment || OrderField.paymentStatus:
      break;
  }

  final valid = _share(values, (v) => _valid(f, v));
  final need = switch (f) {
    OrderField.id || OrderField.number || OrderField.total || OrderField.created => 0.6,
    OrderField.phone || OrderField.status => 0.5,
    _ => 0.3,
  };
  if (valid < need) return 0;
  if ((f == OrderField.id || f == OrderField.number) && !_distinct(values)) return 0;
  final s = base + ctx + 30 * valid;
  return s > 0 ? s : 0;
}

bool _valid(OrderField f, Object? v) {
  if (v == null) return false;
  final t = _text(v);
  switch (f) {
    case OrderField.id || OrderField.number:
      return t != null && t.length <= 64;
    case OrderField.phone:
      return t != null && _isPhone(t);
    case OrderField.total || OrderField.shipping || OrderField.discount || OrderField.paid:
      if (v is bool) return false;
      return _money(v) != null;
    case OrderField.created || OrderField.updated:
      return _when(v) != null;
    case OrderField.status:
      return v is String && t != null && t.length <= 40 && double.tryParse(t) == null;
    case OrderField.name:
      return t != null &&
          t.length >= 2 &&
          t.length <= 80 &&
          RegExp(r'\p{L}', unicode: true).hasMatch(t) &&
          !t.contains('@') &&
          !RegExp(r'^#?\s*\w*\d+$').hasMatch(t);
    case OrderField.address:
      return t != null && t.length >= 4 && RegExp(r'\p{L}', unicode: true).hasMatch(t);
    case OrderField.area || OrderField.city || OrderField.courier || OrderField.payment:
      return t != null && t.length <= 60 && RegExp(r'\p{L}', unicode: true).hasMatch(t);
    case OrderField.paymentStatus:
      return t != null && t.length <= 30;
    case OrderField.tracking:
      return t != null && t.length >= 3 && t.length <= 60;
    case OrderField.note:
      return t != null;
  }
}

double _share(List<Object?> values, bool Function(Object?) ok) {
  if (values.isEmpty) return 0;
  var n = 0;
  for (final v in values) {
    if (v != null && ok(v)) n++;
  }
  return n / values.length;
}

bool _distinct(List<Object?> values) {
  final seen = <String>{};
  for (final v in values) {
    final t = _text(v);
    if (t == null) continue;
    if (!seen.add(t)) return false;
  }
  return true;
}

(String?, Map<ItemField, String>) _itemsMapping(List<Map<String, dynamic>> rows) {
  const arrayNames = [
    'items', 'orderitems', 'products', 'lineitems', 'lines', 'cart', 'cartitems', 'details', 'orderdetails',
    'productlist', 'orderproducts', 'carts', 'itemlist', 'products_list', 'orderlines',
  ];
  String? best;
  var bestScore = 0.0;
  Map<ItemField, String> bestFields = const {};
  for (final e in _arrays(rows).entries) {
    final items = <Map<String, dynamic>>[
      for (final list in e.value)
        if (list != null)
          for (final it in list)
            if (it is Map) Map<String, dynamic>.from(it),
    ];
    if (items.isEmpty) continue;
    final f = _itemFields(items);
    if (!f.containsKey(ItemField.name)) continue;
    if (!f.containsKey(ItemField.qty) && !f.containsKey(ItemField.price) && !f.containsKey(ItemField.lineTotal)) continue;
    var s = f.length.toDouble();
    final leaf = _norm(e.key.split('.').last);
    if (arrayNames.contains(leaf)) s += 3;
    if (_foreign.any(leaf.contains) && !leaf.contains('product') && !leaf.contains('item')) s -= 5;
    if (s > bestScore) {
      bestScore = s;
      best = e.key;
      bestFields = f;
    }
  }
  return (best, bestFields);
}

Map<ItemField, String> _itemFields(List<Map<String, dynamic>> items) {
  const names = <ItemField, List<String>>{
    ItemField.name: ['name', 'title', 'productname', 'producttitle', 'itemname', 'productnameen', 'product', 'description'],
    ItemField.qty: ['qty', 'quantity', 'count', 'units', 'pcs', 'piece', 'pieces', 'itemcount', 'productquantity'],
    ItemField.price: ['price', 'unitprice', 'saleprice', 'sellingprice', 'rate', 'priceperunit', 'eachprice', 'productprice', 'unitcost'],
    ItemField.lineTotal: ['total', 'subtotal', 'linetotal', 'totalprice', 'amount', 'linesubtotal', 'itemtotal'],
    ItemField.sku: ['sku', 'code', 'productcode', 'itemcode', 'barcode', 'variantsku'],
    ItemField.productId: ['productid', 'product', 'itemid', 'variantid', 'variationid', 'id'],
  };
  final cols = _columns(items.take(60).toList());
  final used = <String>{};
  final out = <ItemField, String>{};
  for (final f in const [ItemField.name, ItemField.qty, ItemField.price, ItemField.lineTotal, ItemField.sku, ItemField.productId]) {
    String? best;
    var bestScore = 0.0;
    for (final e in cols.entries) {
      if (used.contains(e.key)) continue;
      final segs = e.key.split('.');
      final leaf = _norm(segs.last);
      final full = segs.map(_norm).join();
      final list = names[f]!;
      var base = 0.0;
      for (var i = 0; i < list.length; i++) {
        if (leaf == list[i] || full == list[i]) {
          base = 100.0 - i;
          break;
        }
      }
      if (base == 0) continue;
      final parents = segs.length - 1;
      final valid = _share(e.value, (v) => switch (f) {
            ItemField.name => _text(v) != null && RegExp(r'\p{L}', unicode: true).hasMatch(_text(v)!) && !_text(v)!.startsWith('http'),
            ItemField.qty || ItemField.price || ItemField.lineTotal => v is! bool && _money(v) != null,
            ItemField.sku || ItemField.productId => _text(v) != null,
          });
      if (valid < 0.6) continue;
      // An item's own name beats its product's name only by a little.
      final s = base - 4.0 * parents + 30 * valid;
      if (s > bestScore) {
        bestScore = s;
        best = e.key;
      }
    }
    if (best != null) {
      used.add(best);
      out[f] = best;
    }
  }
  return out;
}

/// Size, colour and the like from an item's options, to keep variants apart.
List<String> _options(Map item) {
  final out = <String>[];
  for (final key in const ['options', 'attributes', 'variation', 'variant', 'option', 'selectedOptions']) {
    final v = item[key];
    if (v is Map) {
      for (final e in v.entries) {
        final k = '${e.key}'.toLowerCase();
        if (k.contains('image') || k.contains('label') && v.containsKey(k.replaceAll('label', ''))) continue;
        final t = _text(e.value);
        if (t != null && !t.startsWith('http') && t.length <= 30 && e.value is! Map && e.value is! List) out.add(t);
      }
    } else if (v is String && v.trim().isNotEmpty && v.length <= 40 && !v.startsWith('http')) {
      out.add(v.trim());
    }
  }
  for (final key in const ['size', 'color', 'colour']) {
    final t = _text(item[key]);
    if (t != null && t.length <= 30 && !out.contains(t)) out.add(t);
  }
  return out;
}

// ------------------------------------------------------------------ values

String? _text(Object? v) {
  if (v == null || v is Map || v is List) return null;
  final s = '$v'.trim();
  return s.isEmpty || s == 'null' ? null : s;
}

const _bnDigits = '০১২৩৪৫৬৭৮৯';
String _asciiDigits(String s) {
  final b = StringBuffer();
  for (final r in s.runes) {
    final i = _bnDigits.indexOf(String.fromCharCode(r));
    b.write(i >= 0 ? '$i' : String.fromCharCode(r));
  }
  return b.toString();
}

/// A money amount from 1250, "1250", "৳ 1,250.00", "Tk. 1250/-", "১২৫০".
double? _money(Object? v) {
  if (v == null || v is bool) return null;
  if (v is num) return v.toDouble();
  if (v is Map) return _money(v['amount'] ?? v['value'] ?? v['total']);
  final s = _asciiDigits('$v');
  final m = RegExp(r'-?\d[\d,]*(\.\d+)?').firstMatch(s);
  if (m == null) return null;
  // Not money: dates, phone numbers and long ids.
  final rest = s.replaceAll(m.group(0)!, '').trim();
  if (RegExp(r'^\d{1,2}[/\-.]\d{1,2}[/\-.]\d{2,4}').hasMatch(s.trim()) || m.group(0)!.replaceAll(',', '').length > 12) {
    return null;
  }
  if (rest.isNotEmpty &&
      RegExp(r'\p{L}{4,}', unicode: true).hasMatch(rest) &&
      !RegExp(r'(tk|taka|bdt|টাকা)', caseSensitive: false).hasMatch(rest)) {
    return null;
  }
  return double.tryParse(m.group(0)!.replaceAll(',', ''));
}

/// Pass-through for other files: money in the same lenient way.
double? parseMoney(Object? v) => _money(v);

/// Pass-through for other files: a date in the same lenient way.
DateTime? parseWhen(Object? v) => _when(v);

final _dateFormats = [
  'd/M/yyyy H:mm:ss', 'd/M/yyyy H:mm', 'd/M/yyyy h:mm a', 'd/M/yyyy', 'd-M-yyyy H:mm', 'd-M-yyyy', 'd.M.yyyy',
  'd MMM yyyy, h:mm a', 'd MMM yyyy h:mm a', 'd MMM yyyy, H:mm', 'd MMM yyyy', 'd MMMM yyyy', 'MMM d, yyyy h:mm a',
  'MMM d, yyyy', 'MMMM d, yyyy', 'yyyy/M/d H:mm', 'yyyy/M/d', 'EEE, d MMM yyyy', 'EEE MMM d yyyy',
].map((f) => DateFormat(f, 'en_US')).toList();

/// A date from ISO text, epoch seconds/milliseconds, or common written forms
/// (day first, as in Bangladesh). Local times are taken as this device's.
DateTime? _when(Object? v) {
  if (v == null || v is bool) return null;
  if (v is num) {
    if (v > 1e12 && v < 1e14) return DateTime.fromMillisecondsSinceEpoch(v.toInt(), isUtc: true);
    if (v > 1e9 && v < 1e11) return DateTime.fromMillisecondsSinceEpoch(v.toInt() * 1000, isUtc: true);
    return null;
  }
  if (v is Map) return _when(v[r'$date'] ?? v['date']);
  final s = _asciiDigits('$v').trim();
  if (s.length < 6 || s.length > 40) return null;
  if (RegExp(r'^\d+$').hasMatch(s)) return _when(int.tryParse(s));
  if (RegExp(r'^\d{4}-\d{2}-\d{2}').hasMatch(s)) {
    final d = DateTime.tryParse(s);
    if (d != null) return d.toUtc();
  }
  final cleaned = s.replaceAll(RegExp(r'\s+'), ' ').toUpperCase();
  for (final f in _dateFormats) {
    try {
      final d = f.parseStrict(_titleCase(cleaned));
      if (d.year >= 2000 && d.year <= 2100) return d.toUtc();
    } catch (_) {}
  }
  return null;
}

String _titleCase(String s) => s.replaceAllMapped(
    RegExp(r'\b([A-Z])([A-Z]+)\b'), (m) => ['AM', 'PM'].contains(m.group(0)) ? m.group(0)! : '${m.group(1)}${m.group(2)!.toLowerCase()}');

bool _isPhone(String t) {
  final a = _asciiDigits(t).trim();
  if (_isBdPhone(a)) return true;
  // Digits with the usual phone punctuation only: not an id, price or date.
  if (!RegExp(r'^\+?[\d\s\-()]{8,20}$').hasMatch(a)) return false;
  final d = a.replaceAll(RegExp(r'[^0-9]'), '');
  return d.length >= 8 && d.length <= 15;
}

bool _isBdPhone(Object? v) {
  final d = _asciiDigits('$v').replaceAll(RegExp(r'[^0-9]'), '');
  return RegExp(r'^(?:880|0)?1[3-9]\d{8}$').hasMatch(d);
}

bool _isPaid(Object? v) {
  if (v == true) return true;
  final t = _text(v)?.toLowerCase();
  return t == 'paid' || t == 'true' || t == 'yes' || t == 'completed' || t == 'success' || t == 'successful';
}

// ------------------------------------------------------------------ tables

/// Rows from a table (an HTML table or text pasted from a spreadsheet): one
/// map per row, keyed by the header text.
List<Map<String, dynamic>> tableRows(List<String> headers, List<List<String>> rows) {
  final keys = <String>[];
  for (var i = 0; i < headers.length; i++) {
    var k = headers[i].trim().replaceAll('.', ' ').replaceAll('+', ' ');
    if (k.isEmpty) k = 'Column ${i + 1}';
    while (keys.contains(k)) {
      k = '$k ';
    }
    keys.add(k);
  }
  return [
    for (final r in rows)
      if (r.any((c) => c.trim().isNotEmpty))
        {for (var i = 0; i < keys.length && i < r.length; i++) keys[i]: r[i].trim()},
  ];
}

/// Text copied from a website's table or a spreadsheet (tab separated, or
/// comma separated from a CSV file) → header + rows.
(List<String>, List<List<String>>) parsePastedTable(String text) {
  final lines = const LineSplitter().convert(text.replaceAll('\r\n', '\n')).where((l) => l.trim().isNotEmpty).toList();
  if (lines.isEmpty) return (const [], const []);
  final tabs = lines.first.contains('\t');
  List<String> split(String l) => tabs ? l.split('\t') : _csv(l);
  final header = split(lines.first);
  return (header, [for (final l in lines.skip(1)) split(l)]);
}

List<String> _csv(String line) {
  final out = <String>[];
  final b = StringBuffer();
  var quoted = false;
  for (var i = 0; i < line.length; i++) {
    final c = line[i];
    if (quoted) {
      if (c == '"' && i + 1 < line.length && line[i + 1] == '"') {
        b.write('"');
        i++;
      } else if (c == '"') {
        quoted = false;
      } else {
        b.write(c);
      }
    } else if (c == '"') {
      quoted = true;
    } else if (c == ',') {
      out.add(b.toString());
      b.clear();
    } else {
      b.write(c);
    }
  }
  out.add(b.toString());
  return out;
}

// ------------------------------------------------------------------ paging

/// What a list's reply says about further pages, when it says anything.
class PageInfo {
  /// Last page number, if the reply gives it.
  final int? lastPage;

  /// True/false when the reply says whether there are more pages.
  final bool? more;
  const PageInfo({this.lastPage, this.more});
}

PageInfo pageInfo(Object? json, String arrayPath) {
  if (json is! Map) return const PageInfo();
  // Paging details sit next to the list (or one level up).
  final holders = <Map>[json];
  if (arrayPath.contains('.')) {
    final parent = valueAt(json, arrayPath.substring(0, arrayPath.lastIndexOf('.')));
    if (parent is Map) holders.insert(0, parent);
  }
  for (final key in const ['meta', 'pagination', 'paging', 'pageInfo', 'page_info']) {
    final v = json[key];
    if (v is Map) holders.add(v);
  }
  int? last;
  bool? more;
  for (final h in holders) {
    for (final e in h.entries) {
      final k = _norm('${e.key}');
      final v = e.value;
      if (last == null && const ['lastpage', 'totalpages', 'pages', 'pagecount', 'numpages', 'pagestotal'].contains(k)) {
        final n = v is num ? v.toInt() : int.tryParse('$v');
        if (n != null) last = n;
      }
      if (more == null && const ['hasnextpage', 'hasmore', 'hasnext', 'more', 'nextpageexists'].contains(k) && v is bool) more = v;
      if (more == null && const ['nextpageurl', 'next', 'nextpage', 'nextcursor', 'nextlink'].contains(k)) {
        more = v != null && v != false && '$v'.isNotEmpty && '$v' != '0' && '$v' != 'null';
      }
    }
  }
  return PageInfo(lastPage: last, more: more);
}
