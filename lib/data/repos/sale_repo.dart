import 'package:drift/drift.dart';

import '../../core/util.dart';
import '../database.dart';
import 'cash_repo.dart';
import 'contact_repo.dart';
import 'product_repo.dart';
import 'settings_repo.dart';

class CartLine {
  final int? productId;
  final String name;
  final double qty;
  final double price;

  /// Unit cost for profit. Null = take the product's current average cost.
  final double? cost;
  final String? unit;
  final bool trackStock;

  const CartLine({
    this.productId,
    required this.name,
    required this.qty,
    required this.price,
    this.cost,
    this.unit,
    this.trackStock = true,
  });

  double get total => r2(qty * price);

  CartLine copyWith({double? qty, double? price, String? name}) => CartLine(
        productId: productId,
        name: name ?? this.name,
        qty: qty ?? this.qty,
        price: price ?? this.price,
        cost: cost,
        unit: unit,
        trackStock: trackStock,
      );
}

/// What is still sold after partial returns.
extension SaleItemNet on SaleItem {
  double get netQty => r3(qty - returnedQty);
  double get netTotal => r2(total - price * returnedQty);
}

class SaleTotals {
  final double subtotal;
  final double discount;
  final double vat;
  final double deliveryCharge;
  final double total;
  const SaleTotals(this.subtotal, this.discount, this.vat, this.deliveryCharge, this.total);
}

/// Single source of truth for invoice maths (UI preview and saved document).
SaleTotals computeTotals(List<CartLine> lines, {double discount = 0, double vatPercent = 0, double deliveryCharge = 0}) {
  final subtotal = r2(lines.fold<double>(0, (s, l) => s + l.total));
  final disc = r2(discount.clamp(0, subtotal));
  final vat = r2((subtotal - disc) * vatPercent / 100);
  final delivery = r2(deliveryCharge < 0 ? 0 : deliveryCharge);
  return SaleTotals(subtotal, disc, vat, delivery, r2(subtotal - disc + vat + delivery));
}

class SaleRow {
  final Sale sale;
  final String? contactName;
  final int itemCount;
  final String? courier;
  final String? consignmentId;
  final String? courierStatus;
  const SaleRow(this.sale, this.contactName, this.itemCount, {this.courier, this.consignmentId, this.courierStatus});
  double get due => r2(sale.total - sale.paid);
}

class SaleDetail {
  final Sale sale;
  final List<SaleItem> items;
  final Contact? contact;
  final List<Shipment> shipments;
  const SaleDetail(this.sale, this.items, this.contact, this.shipments);
  double get due => r2(sale.total - sale.paid);
  Shipment? get shipment => shipments.isEmpty ? null : shipments.last;

  /// Lines as they stand after partial returns; a fully returned sale keeps its original lines.
  SaleDetail get net {
    if (sale.status == 'returned' || items.every((i) => i.returnedQty <= 0)) return this;
    return SaleDetail(
        sale, [for (final i in items) if (i.netQty > 0) i.copyWith(qty: i.netQty, total: i.netTotal)], contact, shipments);
  }
}

/// Statuses whose money counts as earned revenue.
const revenueStatuses = ['completed', 'delivered', 'partial'];

class SaleRepo {
  final AppDatabase db;
  final SettingsRepo settings;
  final ProductRepo products;
  final ContactRepo contacts;
  final CashRepo cash;
  SaleRepo(this.db, this.settings, this.products, this.contacts, this.cash);

  /// Counter (POS) sale. Anything not paid goes to the customer's khata.
  /// An optional delivery charge is part of the total, so it can be due too.
  Future<int> createSale({
    required List<CartLine> lines,
    double discount = 0,
    double vatPercent = 0,
    double deliveryCharge = 0,
    int? contactId,
    required double paid,
    int? accountId,
    String? note,
    DateTime? date,
  }) =>
      db.transaction(() async {
        final t = computeTotals(lines, discount: discount, vatPercent: vatPercent, deliveryCharge: deliveryCharge);
        final paidAmt = r2(paid.clamp(0, t.total));
        final due = r2(t.total - paidAmt);
        if (due > 0 && contactId == null) throw BizException('due_needs_customer');
        if (paidAmt > 0 && accountId == null) throw BizException('account_required');
        final when = date ?? DateTime.now();
        final id = await insertDocument(
          channel: 'pos',
          status: 'completed',
          lines: lines,
          totals: t,
          paid: paidAmt,
          contactId: contactId,
          accountId: accountId,
          note: note,
          date: when,
        );
        if (contactId != null) {
          await contacts.post(contactId: contactId, kind: 'sale', amount: t.total, refType: 'sale', refId: id, date: when);
          if (paidAmt > 0) {
            await contacts.post(
                contactId: contactId,
                kind: 'payment',
                amount: -paidAmt,
                refType: 'sale',
                refId: id,
                accountId: accountId,
                date: when);
          }
        }
        if (paidAmt > 0) {
          await cash.add(
              accountId: accountId!,
              direction: 1,
              amount: paidAmt,
              source: 'sale',
              refType: 'sale',
              refId: id,
              contactId: contactId,
              date: when);
        }
        return id;
      });

  /// Shared by POS sales and online orders: writes the sale, its lines and
  /// takes the goods out of stock. Must run inside a transaction.
  Future<int> insertDocument({
    required String channel,
    required String status,
    required List<CartLine> lines,
    required SaleTotals totals,
    required double paid,
    int? contactId,
    int? accountId,
    String? note,
    required DateTime date,
    String? shipName,
    String? shipPhone,
    String? shipAddress,
    String? shipArea,
    String? shipCity,
    bool allowNegativeStock = false,
  }) async {
    if (lines.isEmpty) throw BizException('cart_empty');
    for (final l in lines) {
      if (l.qty <= 0) throw BizException('qty_positive');
      if (l.price < 0) throw BizException('price_negative');
    }
    final allowNegative = allowNegativeStock || await settings.flag(K.allowNegativeStock, fallback: true);

    // Resolve product costs and check stock up front.
    final resolved = <(CartLine, double, Product?)>[];
    var costTotal = 0.0;
    for (final l in lines) {
      Product? p;
      if (l.productId != null) p = await products.byId(l.productId!);
      final unitCost = l.cost ?? p?.costPrice ?? 0;
      if (p != null && p.trackStock && !allowNegative) {
        final needed = lines.where((x) => x.productId == p!.id).fold<double>(0, (s, x) => s + x.qty);
        if (needed > p.stock + 0.0001) throw BizException('insufficient_stock:${p.name}');
      }
      costTotal += unitCost * l.qty;
      resolved.add((l, unitCost, p));
    }

    final invoice = await settings.nextInvoiceNo();
    final id = await db.insertRow(db.sales, SalesCompanion.insert(
          invoiceNo: invoice,
          date: date,
          contactId: Value(contactId),
          channel: Value(channel),
          subtotal: Value(totals.subtotal),
          discount: Value(totals.discount),
          vat: Value(totals.vat),
          deliveryCharge: Value(totals.deliveryCharge),
          total: Value(totals.total),
          paid: Value(paid),
          costTotal: Value(r2(costTotal)),
          status: Value(status),
          accountId: Value(accountId),
          note: Value(note == null || note.trim().isEmpty ? null : note.trim()),
          shipName: Value(shipName),
          shipPhone: Value(shipPhone),
          shipAddress: Value(shipAddress),
          shipArea: Value(shipArea),
          shipCity: Value(shipCity),
          createdBy: Value(db.actor),
        ));

    for (final (l, unitCost, p) in resolved) {
      await db.insertRow(db.saleItems, SaleItemsCompanion.insert(
            saleId: id,
            productId: Value(l.productId),
            name: l.name,
            qty: r3(l.qty),
            unit: Value(l.unit ?? p?.unit),
            price: r2(l.price),
            cost: Value(r2(unitCost)),
            total: l.total,
          ));
      if (p != null && p.trackStock) {
        await products.changeStock(p.id, -l.qty, kind: 'sale', refType: 'sale', refId: id, date: date);
      }
    }
    return id;
  }

  /// Puts the tracked items of the sale back on the shelf, minus anything an
  /// earlier partial return already put back.
  Future<void> restock(int saleId, {String kind = 'return'}) async {
    final items = await (db.select(db.saleItems)..where((t) => t.saleId.equals(saleId))).get();
    for (final it in items) {
      final left = r3(it.qty - it.returnedQty);
      if (it.productId == null || left <= 0) continue;
      final p = await products.byId(it.productId!);
      if (p == null || !p.trackStock) continue;
      await products.changeStock(p.id, left, kind: kind, refType: 'sale', refId: saleId);
    }
  }

  /// Full return of a counter sale: stock back, khata reversed, money refunded.
  Future<void> returnSale(int saleId, {int? refundAccountId, String? note}) async {
    final items = await (db.select(db.saleItems)..where((t) => t.saleId.equals(saleId))).get();
    await returnItems(saleId, {for (final it in items) it.id: r3(it.qty - it.returnedQty)},
        refundAccountId: refundAccountId, note: note);
  }

  /// Take back some or all items of a counter sale ([qtyByItem]: sale item id → qty).
  ///
  /// The sale shrinks in place: subtotal, cost, and the bill discount and VAT
  /// (split by value) go down, stock goes back up, and whatever the customer
  /// paid beyond the new total is refunded from [refundAccountId]. When nothing
  /// is left the sale becomes "returned". Returns the refunded amount.
  Future<double> returnItems(int saleId, Map<int, double> qtyByItem, {int? refundAccountId, String? note}) =>
      db.transaction(() async {
        final s = await byId(saleId);
        if (s == null) throw BizException('not_found');
        if (s.channel != 'pos' || s.status != 'completed') throw BizException('cannot_return');
        final items = await (db.select(db.saleItems)..where((t) => t.saleId.equals(saleId))).get();
        final picked = <(SaleItem, double)>[];
        for (final it in items) {
          final q = r3(qtyByItem[it.id] ?? 0);
          if (q <= 0) continue;
          if (q > r3(it.qty - it.returnedQty)) throw BizException('return_too_many');
          picked.add((it, q));
        }
        if (picked.isEmpty) throw BizException('nothing_to_return');
        final everything = items.every((it) => r3(it.qty - it.returnedQty - (qtyByItem[it.id] ?? 0)) <= 0);

        final retSub = r2(picked.fold<double>(0, (a, e) => a + e.$1.price * e.$2));
        final retCost = r2(picked.fold<double>(0, (a, e) => a + e.$1.cost * e.$2));
        final share = s.subtotal <= 0 ? 0.0 : (retSub / s.subtotal).clamp(0.0, 1.0);
        // The last return takes whatever is left, so rounding never strands a paisa.
        final retDisc = everything ? s.discount : r2(s.discount * share);
        final retVat = everything ? s.vat : r2(s.vat * share);
        final retValue = everything ? s.total : r2(retSub - retDisc + retVat);
        final newTotal = r2(s.total - retValue);
        final refund = s.paid > newTotal ? r2(s.paid - newTotal) : 0.0;
        final refundAcc = refundAccountId ?? s.accountId;
        if (refund > 0 && refundAcc == null) throw BizException('account_required');
        final now = DateTime.now();

        for (final (it, q) in picked) {
          await (db.update(db.saleItems)..where((t) => t.id.equals(it.id)))
              .write(SaleItemsCompanion(returnedQty: Value(r3(it.returnedQty + q))));
          if (it.productId == null) continue;
          final p = await products.byId(it.productId!);
          if (p != null && p.trackStock) await products.changeStock(p.id, q, kind: 'return', refType: 'sale', refId: saleId);
        }
        if (s.contactId != null) {
          await contacts.post(
              contactId: s.contactId!, kind: 'return', amount: -retValue, refType: 'sale', refId: saleId, date: now, note: note);
          if (refund > 0) {
            await contacts.post(
                contactId: s.contactId!,
                kind: 'refund',
                amount: refund,
                refType: 'sale',
                refId: saleId,
                accountId: refundAcc,
                date: now);
          }
        }
        if (refund > 0) {
          await cash.add(
              accountId: refundAcc!,
              direction: -1,
              amount: refund,
              source: 'refund',
              refType: 'sale',
              refId: saleId,
              contactId: s.contactId,
              note: note,
              date: now);
        }
        final notes = [
          if (s.note != null && s.note!.isNotEmpty) s.note!,
          if (note != null && note.trim().isNotEmpty) note.trim(),
        ];
        final noteValue = Value(notes.isEmpty ? null : notes.join(' · '));
        await (db.update(db.sales)..where((t) => t.id.equals(saleId))).write(everything
            // A fully returned sale keeps its figures for reference; reports skip it by status.
            ? SalesCompanion(status: const Value('returned'), updatedAt: Value(now), note: noteValue)
            : SalesCompanion(
                subtotal: Value(r2(s.subtotal - retSub)),
                discount: Value(r2(s.discount - retDisc)),
                vat: Value(r2(s.vat - retVat)),
                total: Value(newTotal),
                paid: Value(r2(s.paid - refund)),
                costTotal: Value(r2(s.costTotal - retCost)),
                updatedAt: Value(now),
                note: noteValue,
              ));
        return refund;
      });

  /// What a partial return would do, for the dialog preview (no changes made).
  ({double value, double refund, double dueCut}) previewReturn(Sale s, List<SaleItem> items, Map<int, double> qtyByItem) {
    final retSub = r2(items.fold<double>(0, (a, it) => a + it.price * (qtyByItem[it.id] ?? 0)));
    if (retSub <= 0) return (value: 0, refund: 0, dueCut: 0);
    final everything = items.every((it) => r3(it.qty - it.returnedQty - (qtyByItem[it.id] ?? 0)) <= 0);
    final share = s.subtotal <= 0 ? 0.0 : (retSub / s.subtotal).clamp(0.0, 1.0);
    final value = everything ? s.total : r2(retSub - r2(s.discount * share) + r2(s.vat * share));
    final newTotal = r2(s.total - value);
    final refund = s.paid > newTotal ? r2(s.paid - newTotal) : 0.0;
    return (value: value, refund: refund, dueCut: r2(value - refund));
  }

  Future<Sale?> byId(int id) => (db.select(db.sales)..where((t) => t.id.equals(id))).getSingleOrNull();

  Future<SaleDetail?> detail(int id) async {
    final s = await byId(id);
    if (s == null) return null;
    final items = await (db.select(db.saleItems)..where((t) => t.saleId.equals(id))).get();
    final contact = s.contactId == null ? null : await contacts.byId(s.contactId!);
    final ships = await (db.select(db.shipments)
          ..where((t) => t.saleId.equals(id))
          ..orderBy([(t) => OrderingTerm.asc(t.id)]))
        .get();
    return SaleDetail(s, items, contact, ships);
  }

  Stream<SaleDetail?> watchDetail(int id) => db
      .customSelect('SELECT 1', readsFrom: {db.sales, db.saleItems, db.shipments, db.contacts})
      .watch()
      .asyncMap((_) => detail(id));

  /// List for the Sales and Orders screens.
  Stream<List<SaleRow>> watchList({
    required DateRange range,
    String channel = 'pos',
    String query = '',
    List<String>? statuses,
    int? contactId,
    int limit = 1000,
  }) {
    final where = StringBuffer('s.date BETWEEN ? AND ? AND s.channel = ?');
    final vars = <Variable>[
      Variable.withDateTime(range.from),
      Variable.withDateTime(range.to),
      Variable.withString(channel),
    ];
    if (statuses != null && statuses.isNotEmpty) {
      where.write(' AND s.status IN (${List.filled(statuses.length, '?').join(',')})');
      vars.addAll(statuses.map(Variable.withString));
    }
    if (contactId != null) {
      where.write(' AND s.contact_id = ?');
      vars.add(Variable.withInt(contactId));
    }
    final term = query.trim();
    if (term.isNotEmpty) {
      final phone = normalizePhone(term);
      where.write(
          ' AND (s.invoice_no LIKE ? OR c.name LIKE ? OR s.ship_name LIKE ? OR s.ship_phone LIKE ? OR c.phone LIKE ? OR sh.consignment_id LIKE ? OR sh.tracking_code LIKE ?)');
      final like = '%$term%';
      final phoneLike = '%${phone.isEmpty ? term : phone}%';
      vars.addAll([like, like, like, phoneLike, phoneLike, like, like].map(Variable.withString));
    }
    return db
        .customSelect(
          '''SELECT s.*, c.name AS contact_name,
               (SELECT COUNT(*) FROM sale_items i WHERE i.sale_id = s.id) AS item_count,
               sh.courier AS sh_courier, sh.consignment_id AS sh_cid, sh.courier_status AS sh_status
             FROM sales s
             LEFT JOIN contacts c ON c.id = s.contact_id
             LEFT JOIN shipments sh ON sh.id = (SELECT MAX(id) FROM shipments x WHERE x.sale_id = s.id)
             WHERE $where
             ORDER BY s.date DESC, s.id DESC LIMIT $limit''',
          variables: vars,
          readsFrom: {db.sales, db.contacts, db.saleItems, db.shipments},
        )
        .watch()
        .map((rows) => rows
            .map((r) => SaleRow(
                  db.sales.map(r.data),
                  r.readNullable<String>('contact_name'),
                  r.read<int>('item_count'),
                  courier: r.readNullable<String>('sh_courier'),
                  consignmentId: r.readNullable<String>('sh_cid'),
                  courierStatus: r.readNullable<String>('sh_status'),
                ))
            .toList());
  }

  /// Invoices and orders matching an invoice number, name, phone or tracking code (global search).
  Future<List<SaleRow>> searchDocs(String query, {int limit = 8}) async {
    final term = query.trim();
    if (term.isEmpty) return const [];
    final phone = normalizePhone(term);
    // Escape LIKE wildcards so "INV_10" or "%" match literally.
    String esc(String v) => v.replaceAll('!', '!!').replaceAll('%', '!%').replaceAll('_', '!_');
    final like = '%${esc(term)}%';
    final phoneLike = '%${esc(phone.isEmpty ? term : phone)}%';
    const e = "ESCAPE '!'";
    final rows = await db.customSelect(
      '''SELECT s.*, c.name AS contact_name,
           (SELECT COUNT(*) FROM sale_items i WHERE i.sale_id = s.id) AS item_count
         FROM sales s LEFT JOIN contacts c ON c.id = s.contact_id
         WHERE s.invoice_no LIKE ? $e OR c.name LIKE ? $e OR s.ship_name LIKE ? $e OR s.ship_phone LIKE ? $e OR c.phone LIKE ? $e
            OR EXISTS (SELECT 1 FROM shipments sh WHERE sh.sale_id = s.id AND (sh.consignment_id LIKE ? $e OR sh.tracking_code LIKE ? $e))
         ORDER BY s.date DESC, s.id DESC LIMIT $limit''',
      variables: [like, like, like, phoneLike, phoneLike, like, like].map(Variable.withString).toList(),
      readsFrom: {db.sales, db.contacts, db.saleItems, db.shipments},
    ).get();
    return rows.map((r) => SaleRow(db.sales.map(r.data), r.readNullable<String>('contact_name'), r.read<int>('item_count'))).toList();
  }

  Stream<List<SaleRow>> watchRecent({int limit = 8}) => watchListAll(limit: limit);

  /// Recent documents across both channels (dashboard).
  Stream<List<SaleRow>> watchListAll({int limit = 8}) => db
      .customSelect(
        '''SELECT s.*, c.name AS contact_name,
             (SELECT COUNT(*) FROM sale_items i WHERE i.sale_id = s.id) AS item_count
           FROM sales s LEFT JOIN contacts c ON c.id = s.contact_id
           ORDER BY s.date DESC, s.id DESC LIMIT $limit''',
        readsFrom: {db.sales, db.contacts, db.saleItems},
      )
      .watch()
      .map((rows) =>
          rows.map((r) => SaleRow(db.sales.map(r.data), r.readNullable<String>('contact_name'), r.read<int>('item_count'))).toList());
}
