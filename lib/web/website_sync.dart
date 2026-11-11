import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:http/http.dart' as http;

import '../core/i18n.dart';
import '../core/util.dart';
import '../data/biz.dart';
import 'browser_connector.dart';
import 'browser_page.dart';
import 'connectors.dart';

/// The owner's website connection, kept in settings (`website`).
class WebsiteConfig {
  /// woo | json | browser (any website, read through the built-in browser)
  final String platform;
  final String url;
  final String key;
  final String secret;

  /// Orders placed before this are not imported.
  final DateTime? importFrom;

  /// How often to check, in minutes (0 = only when asked).
  final int minutes;

  /// Also bring in products and prices.
  final bool products;

  /// Copy each product's stock from the website (the website is the master).
  final bool stockFromWebsite;
  final bool updatePrices;

  /// The device that fetches orders when the shop is shared through Google
  /// Drive, so two devices never import the same order twice.
  final String? puller;
  final bool enabled;

  /// For `browser`: the admin page and order lists chosen in the built-in
  /// browser. No password or sign-in token is kept here: the built-in
  /// browser stays signed in to the website the way any browser does.
  final BrowserSource? browser;

  const WebsiteConfig({
    this.platform = 'woo',
    this.url = '',
    this.key = '',
    this.secret = '',
    this.importFrom,
    this.minutes = 5,
    this.products = true,
    this.stockFromWebsite = false,
    this.updatePrices = true,
    this.puller,
    this.enabled = false,
    this.browser,
  });

  /// WooCommerce needs its key and secret; a BizKhata API website only needs
  /// its address (the key is optional, see docs/website-api.md); any other
  /// website needs an order list chosen in the built-in browser.
  bool get ready => platform == 'browser'
      ? browser != null
      : url.trim().isNotEmpty && (platform != 'woo' || (key.trim().isNotEmpty && secret.trim().isNotEmpty));

  bool get isBrowser => platform == 'browser';

  /// Status changes made here go back to the website (BizKhata API websites;
  /// WooCommerce and websites read through the browser stay read-only).
  bool get canPush => platform == 'json';

  Map<String, Object?> toJson() => {
        'platform': platform,
        'url': url.trim(),
        'key': key.trim(),
        'secret': secret.trim(),
        'importFrom': importFrom?.toIso8601String(),
        'minutes': minutes,
        'products': products,
        'stockFromWebsite': stockFromWebsite,
        'updatePrices': updatePrices,
        'puller': puller,
        'enabled': enabled,
        'browser': ?browser?.toJson(),
      };

  factory WebsiteConfig.fromJson(Map<String, dynamic> j) => WebsiteConfig(
        platform: j['platform'] as String? ?? 'woo',
        url: j['url'] as String? ?? '',
        key: j['key'] as String? ?? '',
        secret: j['secret'] as String? ?? '',
        importFrom: DateTime.tryParse('${j['importFrom']}'),
        minutes: (j['minutes'] as num?)?.toInt() ?? 5,
        products: j['products'] as bool? ?? true,
        stockFromWebsite: j['stockFromWebsite'] as bool? ?? false,
        updatePrices: j['updatePrices'] as bool? ?? true,
        puller: j['puller'] as String?,
        enabled: j['enabled'] as bool? ?? false,
        browser: BrowserSource.fromJson(j['browser']),
      );

  WebsiteConfig copyWith({String? puller, bool? enabled}) => WebsiteConfig(
        platform: platform,
        url: url,
        key: key,
        secret: secret,
        importFrom: importFrom,
        minutes: minutes,
        products: products,
        stockFromWebsite: stockFromWebsite,
        updatePrices: updatePrices,
        puller: puller ?? this.puller,
        enabled: enabled ?? this.enabled,
        browser: browser,
      );

  /// [page] is the hidden browser page, needed for `browser` websites;
  /// [unchanged] tells it which orders are already here as they are.
  StoreConnector connector({http.Client? client, PageClient? page, Future<bool> Function(RemoteOrder o)? unchanged}) =>
      switch (platform) {
        'json' => JsonApiConnector(url: url, key: key, client: client),
        'browser' => BrowserConnector(
            source: browser!,
            page: page ?? (throw StateError('the built-in browser is needed for this website')),
            importFrom: importFrom,
            unchanged: unchanged,
          ),
        _ => WooConnector(url: url, key: key, secret: secret, client: client),
      };
}

class WebsiteReport {
  final DateTime at;
  int created = 0;
  int updated = 0;
  int products = 0;
  int skipped = 0;

  /// Status changes made here and sent to the website.
  int pushed = 0;
  final errors = <String>[];
  WebsiteReport([DateTime? at]) : at = at ?? DateTime.now();

  Map<String, Object?> toJson() => {
        'at': at.toIso8601String(),
        'created': created,
        'updated': updated,
        'products': products,
        'skipped': skipped,
        'pushed': pushed,
        'errors': errors.take(5).toList(),
      };

  factory WebsiteReport.fromJson(Map<String, dynamic> j) => WebsiteReport(DateTime.tryParse('${j['at']}'))
    ..created = (j['created'] as num?)?.toInt() ?? 0
    ..updated = (j['updated'] as num?)?.toInt() ?? 0
    ..products = (j['products'] as num?)?.toInt() ?? 0
    ..skipped = (j['skipped'] as num?)?.toInt() ?? 0
    ..pushed = (j['pushed'] as num?)?.toInt() ?? 0
    ..errors.addAll([for (final e in j['errors'] as List? ?? const []) '$e']);
}

/// What the website said when it refused a change made here.
class PushRefusal {
  /// The status here that the website did not accept.
  final String status;
  final String message;
  const PushRefusal(this.status, this.message);

  String toJson() => jsonEncode({'for': status, 'msg': message});

  static PushRefusal? parse(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final j = jsonDecode(raw) as Map;
      return PushRefusal('${j['for']}', '${j['msg'] ?? ''}');
    } catch (_) {
      return null;
    }
  }
}

/// Settings keys used by the website connection.
abstract final class WebKeys {
  static const config = 'website';
  static const orderCursor = 'web_cursor_orders';
  static const productCursor = 'web_cursor_products';
  static const last = 'web_last';
  static const account = 'web_account';
}

Future<WebsiteConfig> loadWebsiteConfig(Biz biz) async => WebsiteConfig.fromJson(await biz.settings.getJson(WebKeys.config));

/// Keeps this business and a website's orders in step, again and again
/// without duplicates:
///
/// * a new order becomes an online order here, linked to the website's order;
/// * later status changes on the website move the order along here
///   (accepted, shipped, delivered with the money, returned, cancelled);
/// * status changes made here (confirm, courier, delivered, returned,
///   cancelled) go back to the website, when it can take them;
/// * products are matched by link, then SKU, then exact name.
class WebsiteSync {
  final Biz biz;
  final StoreConnector conn;
  final String source;
  WebsiteSync(this.biz, this.conn, {this.source = 'web'});

  Future<WebsiteReport> run(WebsiteConfig cfg, {int maxPages = 20}) async {
    final rep = WebsiteReport();
    await biz.settings.setFlag(K.onlineEnabled, true);
    await _orders(cfg, rep, maxPages);
    // After reading: whatever is still further along here goes to the website.
    if (conn.canPush) await push(rep);
    // Products last: with "stock from website", the website's numbers (which
    // already include these orders) then overwrite ours.
    if (cfg.products) await _products(cfg, rep, maxPages);
    await biz.settings.setJson(WebKeys.last, rep.toJson());
    return rep;
  }

  /// Bring in orders already in hand (pasted from a table) once, without
  /// moving the reading position of the website connection.
  Future<WebsiteReport> importOrders(List<RemoteOrder> list, WebsiteConfig cfg) async {
    final rep = WebsiteReport();
    await biz.settings.setFlag(K.onlineEnabled, true);
    for (final o in list) {
      try {
        await _order(o, cfg, rep);
      } catch (e) {
        rep.errors.add('#${o.number}: ${errorText(e)}');
      }
    }
    return rep;
  }

  /// True when the website's order [o] is already here and hasn't changed since.
  static Future<bool> isUnchanged(Biz biz, RemoteOrder o, {String source = 'web'}) async {
    final l = await (biz.db.select(biz.db.extLinks)
          ..where((t) => t.kind.equals('order') & t.source.equals(source) & t.extId.equals(o.id)))
        .getSingleOrNull();
    return l != null && l.extUpdated == (o.version ?? o.updated.toUtc().toIso8601String());
  }

  // ------------------------------------------------------------------ links

  Future<ExtLink?> _link(String kind, String extId) => (biz.db.select(biz.db.extLinks)
        ..where((t) => t.kind.equals(kind) & t.source.equals(source) & t.extId.equals(extId)))
      .getSingleOrNull();

  Future<void> _saveLink(String kind, String extId, int localId, String? updated, {String? extStatus}) async {
    final existing = await _link(kind, extId);
    if (existing != null) {
      await (biz.db.update(biz.db.extLinks)..where((t) => t.id.equals(existing.id))).write(ExtLinksCompanion(
            localId: Value(localId),
            extUpdated: Value(updated),
            extStatus: extStatus == null ? const Value.absent() : Value(extStatus),
          ));
    } else {
      await biz.db.insertRow(
          biz.db.extLinks,
          ExtLinksCompanion.insert(
              kind: kind,
              source: source,
              extId: extId,
              localId: localId,
              extUpdated: Value(updated),
              extStatus: Value(extStatus)));
    }
  }

  /// The money account that website payments go into (created on first use).
  Future<int> _account() async {
    final saved = int.tryParse(await biz.settings.getOr(WebKeys.account, ''));
    if (saved != null) {
      final acc = await biz.cash.byId(saved);
      if (acc != null) {
        if (!acc.active) await biz.cash.setAccountActive(acc.id, true);
        return acc.id;
      }
    }
    final id = await biz.cash.createAccount(isBangla ? 'ওয়েবসাইট পেমেন্ট' : 'Website payments', kind: 'mobile');
    await biz.settings.set(WebKeys.account, '$id');
    return id;
  }

  // ----------------------------------------------------------------- orders

  Future<void> _orders(WebsiteConfig cfg, WebsiteReport rep, int maxPages) async {
    final saved = DateTime.tryParse(await biz.settings.getOr(WebKeys.orderCursor, ''));
    final since = saved ?? cfg.importFrom;
    var cursor = saved;
    for (var page = 1; page <= maxPages; page++) {
      final pg = await conn.orders(since: since?.subtract(const Duration(minutes: 1)), page: page);
      for (final o in pg.items) {
        try {
          await _order(o, cfg, rep);
        } catch (e) {
          rep.errors.add('#${o.number}: ${errorText(e)}');
        }
        if (cursor == null || o.updated.isAfter(cursor)) cursor = o.updated;
      }
      if (cursor != null) await biz.settings.set(WebKeys.orderCursor, cursor.toUtc().toIso8601String());
      if (!pg.more) break;
    }
  }

  Future<void> _order(RemoteOrder o, WebsiteConfig cfg, WebsiteReport rep) async {
    final stamp = o.version ?? o.updated.toUtc().toIso8601String();
    final status = conn.mapStatus(o);
    final remote = conn.localStatus(o);
    final link = await _link('order', o.id);
    if (link == null) {
      // Don't bring in orders that were already dead, or older than the chosen start date.
      if (status == WebStatus.skip || status == WebStatus.cancelled || status == WebStatus.returned) {
        rep.skipped++;
        return;
      }
      if (cfg.importFrom != null && o.created.isBefore(cfg.importFrom!)) {
        rep.skipped++;
        return;
      }
      final lines = <CartLine>[for (final l in o.lines) await _line(l, cfg)];
      var discount = o.discount;
      // Keep the website's total exactly, whatever extra fees or rounding it used.
      final diff = r2(o.total - computeTotals(lines, discount: discount, deliveryCharge: o.shipping).total);
      if (diff > 0.009) {
        lines.add(CartLine(name: isBangla ? 'অন্যান্য চার্জ' : 'Other charges', qty: 1, price: diff, trackStock: false));
      } else if (diff < -0.009) {
        discount = r2(discount - diff);
      }
      if (lines.isEmpty) lines.add(CartLine(name: 'Order #${o.number}', qty: 1, price: o.total, trackStock: false));
      final paid = r2(o.paid.clamp(0, o.total));
      final id = await biz.orders.create(
        name: o.name.trim().isEmpty ? (isBangla ? 'ওয়েবসাইট কাস্টমার' : 'Website customer') : o.name,
        phone: o.phone,
        address: o.address.trim().isEmpty ? '-' : o.address,
        area: o.area,
        city: o.city,
        lines: lines,
        discount: discount,
        deliveryCharge: o.shipping,
        advance: paid,
        advanceAccountId: paid > 0 ? await _account() : null,
        note: [isBangla ? 'ওয়েবসাইট অর্ডার #${o.number}' : 'Website order #${o.number}', ?o.payment, ?o.note].join(' · '),
        date: o.created.toLocal(),
        imported: true,
      );
      await _saveLink('order', o.id, id, stamp, extStatus: remote);
      await _follow(id, status, o, remote);
      rep.created++;
      return;
    }
    if (link.extUpdated == stamp) return;
    if (await _follow(link.localId, status, o, remote)) rep.updated++;
    await _saveLink('order', o.id, link.localId, stamp, extStatus: remote);
  }

  /// Move the order here forward to match the website. Never moves backwards.
  Future<bool> _follow(int id, WebStatus status, RemoteOrder o, String? remote) async {
    final s = await biz.sales.byId(id);
    if (s == null) return false;
    final waiting = s.status == 'pending' || s.status == 'confirmed';
    switch (status) {
      case WebStatus.open when remote == 'confirmed' && s.status == 'pending':
        // Accepted on the website.
        await biz.orders.confirm(id);
      case WebStatus.shipped:
        if (!waiting) return false;
        await biz.orders.bookManual(id, courier: 'website', trackingCode: o.tracking);
      case WebStatus.delivered:
        if (!waiting && s.status != 'booked') return false;
        await biz.orders.markDelivered(id, accountId: await _account());
      case WebStatus.returned:
        if (s.status == 'booked') {
          await biz.orders.markReturned(id);
        } else if (waiting) {
          await biz.orders.cancel(id);
        } else {
          return false;
        }
      case WebStatus.cancelled:
        if (!waiting) return false;
        await biz.orders.cancel(id);
      case WebStatus.open:
      case WebStatus.skip:
        return false;
    }
    return true;
  }

  // ------------------------------------------------------------- push back

  /// Send the website every status change made here that it doesn't have yet.
  ///
  /// Only orders that came from the website, only when the order here is
  /// further along than the website's last known status. A change the website
  /// refuses is remembered on the link (shown on the order) and not tried
  /// again until the order changes here. With no internet the rest waits for
  /// the next round.
  Future<int> push(WebsiteReport rep) async {
    if (!conn.canPush) return 0;
    final rows = await biz.db.customSelect(
      '''SELECT l.id AS link_id, l.ext_id, l.ext_status, l.push_error, s.id AS sale_id, s.status, s.invoice_no
         FROM ext_links l JOIN sales s ON s.id = l.local_id
         WHERE l.kind = 'order' AND l.source = ? AND l.ext_status IS NOT NULL AND s.status <> l.ext_status
         ORDER BY s.updated_at''',
      variables: [Variable.withString(source)],
      readsFrom: {biz.db.extLinks, biz.db.sales},
    ).get();
    var sent = 0;
    for (final r in rows) {
      final local = r.read<String>('status');
      final known = r.read<String>('ext_status');
      if (orderStatusRank(local) <= orderStatusRank(known)) continue;
      if (PushRefusal.parse(r.readNullable<String>('push_error'))?.status == local) continue;
      final word = pushStatusName(local);
      if (word == null) continue;
      final linkId = r.read<int>('link_id');
      // Courier details only for parcels booked here, not ones the website reported.
      final last = await biz.orders.lastShipment(r.read<int>('sale_id'));
      final ship = last != null && last.courier != 'website' ? last : null;
      try {
        final after = await conn.pushStatus(
          r.read<String>('ext_id'),
          StatusPush(word, courier: ship?.courier, trackingCode: ship?.trackingCode, consignmentId: ship?.consignmentId),
        );
        final now = after == null ? local : (localStatusOf(after) ?? local);
        if (orderStatusRank(now) < orderStatusRank(local)) {
          // Answered OK but stayed behind: treat it as a refusal, or it would be sent every round.
          await _updateLink(
              linkId,
              ExtLinksCompanion(
                  extStatus: Value(now), pushError: Value(PushRefusal(local, 'the website still shows "$after"').toJson())));
          rep.errors.add('${r.read<String>('invoice_no')}: ${T.e_web_refused.f({'x': 'the website still shows "$after"'})}');
        } else {
          await _updateLink(linkId, ExtLinksCompanion(extStatus: Value(now), pushError: const Value(null)));
          sent++;
        }
      } on WebsiteException catch (e) {
        if (e.code != 'refused') {
          // No internet or a bad key: everything else would fail the same way.
          rep.errors.add(errorText(e));
          break;
        }
        final now = e.remoteStatus == null ? null : localStatusOf(e.remoteStatus!);
        await _updateLink(
            linkId,
            ExtLinksCompanion(
              pushError: Value(PushRefusal(local, e.detail ?? '').toJson()),
              extStatus: now == null ? const Value.absent() : Value(now),
            ));
        rep.errors.add('${r.read<String>('invoice_no')}: ${errorText(e)}');
      }
    }
    rep.pushed += sent;
    return sent;
  }

  Future<void> _updateLink(int id, ExtLinksCompanion c) =>
      (biz.db.update(biz.db.extLinks)..where((t) => t.id.equals(id))).write(c);

  Future<CartLine> _line(RemoteLine l, WebsiteConfig cfg) async {
    final p = await _match(l.productId, l.sku, l.name) ??
        await _create(id: l.productId, sku: l.sku, name: l.name, price: l.price, stock: 0, tracks: true);
    return CartLine(productId: p.id, name: l.name, qty: l.qty, price: l.price, unit: p.unit, trackStock: p.trackStock);
  }

  Future<Product?> _match(String? extId, String? sku, String name) async {
    if (extId != null) {
      final link = await _link('product', extId);
      if (link != null) {
        final p = await biz.products.byId(link.localId);
        if (p != null && p.active) return p;
      }
    }
    Product? p;
    if (sku != null && sku.isNotEmpty) p = await biz.products.byCode(sku);
    p ??= await biz.products.byName(name);
    if (p != null && extId != null) await _saveLink('product', extId, p.id, null);
    return p;
  }

  Future<Product> _create(
      {String? id, String? sku, required String name, required double price, required double stock, required bool tracks}) async {
    final pid = await biz.products.create(
      ProductInput(name: name, sku: sku, unit: 'pcs', salePrice: price, trackStock: tracks),
      openingStock: tracks ? stock : 0,
    );
    if (id != null) await _saveLink('product', id, pid, null);
    return (await biz.products.byId(pid))!;
  }

  // --------------------------------------------------------------- products

  Future<void> _products(WebsiteConfig cfg, WebsiteReport rep, int maxPages) async {
    final saved = DateTime.tryParse(await biz.settings.getOr(WebKeys.productCursor, ''));
    var cursor = saved;
    for (var page = 1; page <= maxPages; page++) {
      final pg = await conn.products(since: saved?.subtract(const Duration(minutes: 1)), page: page);
      for (final rp in pg.items) {
        try {
          if (await _product(rp, cfg)) rep.products++;
        } catch (e) {
          rep.errors.add('${rp.name}: ${errorText(e)}');
        }
        if (cursor == null || rp.updated.isAfter(cursor)) cursor = rp.updated;
      }
      if (cursor != null) await biz.settings.set(WebKeys.productCursor, cursor.toUtc().toIso8601String());
      if (!pg.more) break;
    }
  }

  /// True when something changed here.
  Future<bool> _product(RemoteProduct rp, WebsiteConfig cfg) async {
    final p = await _match(rp.id, rp.sku, rp.name);
    if (p == null) {
      await _create(
          id: rp.id, sku: rp.sku, name: rp.name, price: rp.price ?? 0, stock: rp.stock ?? 0, tracks: rp.tracksStock);
      return true;
    }
    var changed = false;
    if (cfg.updatePrices && rp.price != null && (rp.price! - p.salePrice).abs() > 0.009) {
      await biz.products.update(p.id, ProductInput.of(p).withSalePrice(rp.price!));
      changed = true;
    }
    if (cfg.stockFromWebsite && rp.tracksStock && rp.stock != null && p.trackStock && (rp.stock! - p.stock).abs() > 0.0005) {
      await biz.products.setStock(p.id, rp.stock!, note: isBangla ? 'ওয়েবসাইট' : 'Website');
      changed = true;
    }
    return changed;
  }
}

/// A short description of the last check, e.g. "3 new orders, 1 updated".
String websiteReportText(WebsiteReport r) {
  final parts = [
    if (r.created > 0) T.webNewOrders.f({'n': r.created}),
    if (r.updated > 0) T.webUpdatedOrders.f({'n': r.updated}),
    if (r.pushed > 0) T.webPushedOrders.f({'n': r.pushed}),
    if (r.products > 0) T.webProductsChanged.f({'n': r.products}),
  ];
  return parts.isEmpty ? T.webNothingNew.s : parts.join(', ');
}
