import 'package:drift/drift.dart';

import '../../core/util.dart';
import '../database.dart';
import 'cash_repo.dart';
import 'contact_repo.dart';
import 'product_repo.dart';
import 'settings_repo.dart';

class PurchaseLine {
  final int? productId;
  final String name;
  final double qty;
  final double unitCost;

  /// Optionally update the product's selling price while restocking.
  final double? newSalePrice;
  const PurchaseLine({this.productId, required this.name, required this.qty, required this.unitCost, this.newSalePrice});
  double get total => r2(qty * unitCost);
}

class PurchaseRow {
  final Purchase purchase;
  final String? supplierName;
  final int itemCount;
  const PurchaseRow(this.purchase, this.supplierName, this.itemCount);
  double get due => r2(purchase.total - purchase.paid);
}

class PurchaseDetail {
  final Purchase purchase;
  final List<PurchaseItem> items;
  final Contact? supplier;
  const PurchaseDetail(this.purchase, this.items, this.supplier);
}

class PurchaseRepo {
  final AppDatabase db;
  final SettingsRepo settings;
  final ProductRepo products;
  final ContactRepo contacts;
  final CashRepo cash;
  PurchaseRepo(this.db, this.settings, this.products, this.contacts, this.cash);

  /// Stock in from a supplier. Unpaid part becomes a payable on the supplier's khata.
  Future<int> create({
    required List<PurchaseLine> lines,
    int? supplierId,
    double discount = 0,
    required double paid,
    int? accountId,
    String? note,
    DateTime? date,
  }) =>
      db.transaction(() async {
        if (lines.isEmpty) throw BizException('cart_empty');
        for (final l in lines) {
          if (l.qty <= 0) throw BizException('qty_positive');
          if (l.unitCost < 0) throw BizException('price_negative');
        }
        final subtotal = r2(lines.fold<double>(0, (s, l) => s + l.total));
        final disc = r2(discount.clamp(0, subtotal));
        final total = r2(subtotal - disc);
        final paidAmt = r2(paid.clamp(0, total));
        if (paidAmt < total && supplierId == null) throw BizException('due_needs_supplier');
        if (paidAmt > 0 && accountId == null) throw BizException('account_required');
        final when = date ?? DateTime.now();
        final ref = await settings.nextPurchaseNo();

        final id = await db.insertRow(db.purchases, PurchasesCompanion.insert(
              refNo: ref,
              date: when,
              contactId: Value(supplierId),
              subtotal: Value(subtotal),
              discount: Value(disc),
              total: Value(total),
              paid: Value(paidAmt),
              accountId: Value(accountId),
              note: Value(note == null || note.trim().isEmpty ? null : note.trim()),
              createdBy: Value(db.actor),
            ));

        // Spread the bill discount over lines so average cost reflects what was really paid.
        final factor = subtotal == 0 ? 1.0 : total / subtotal;
        for (final l in lines) {
          await db.insertRow(db.purchaseItems, PurchaseItemsCompanion.insert(
                purchaseId: id,
                productId: Value(l.productId),
                name: l.name,
                qty: r3(l.qty),
                unitCost: r2(l.unitCost),
                total: l.total,
              ));
          if (l.productId == null) continue;
          final p = await products.byId(l.productId!);
          if (p == null) continue;
          final effCost = l.unitCost * factor;
          final onHand = p.stock > 0 ? p.stock : 0.0;
          final newCost = (onHand + l.qty) == 0 ? effCost : (onHand * p.costPrice + l.qty * effCost) / (onHand + l.qty);
          await (db.update(db.products)..where((t) => t.id.equals(p.id))).write(ProductsCompanion(
                costPrice: Value(r2(newCost)),
                salePrice: l.newSalePrice != null && l.newSalePrice! > 0 ? Value(r2(l.newSalePrice!)) : const Value.absent(),
              ));
          if (p.trackStock) {
            await products.changeStock(p.id, l.qty, kind: 'purchase', refType: 'purchase', refId: id, date: when);
          }
        }

        if (supplierId != null) {
          await contacts.post(contactId: supplierId, kind: 'purchase', amount: -total, refType: 'purchase', refId: id, date: when);
          if (paidAmt > 0) {
            await contacts.post(
                contactId: supplierId,
                kind: 'payment',
                amount: paidAmt,
                refType: 'purchase',
                refId: id,
                accountId: accountId,
                date: when);
          }
        }
        if (paidAmt > 0) {
          await cash.add(
              accountId: accountId!,
              direction: -1,
              amount: paidAmt,
              source: 'purchase',
              refType: 'purchase',
              refId: id,
              contactId: supplierId,
              date: when);
        }
        return id;
      });

  /// Undo a purchase: stock goes back out, supplier khata and cash reversed.
  Future<void> cancel(int id) => db.transaction(() async {
        final p = await (db.select(db.purchases)..where((t) => t.id.equals(id))).getSingleOrNull();
        if (p == null || p.status != 'completed') return;
        final items = await (db.select(db.purchaseItems)..where((t) => t.purchaseId.equals(id))).get();
        for (final it in items) {
          if (it.productId == null) continue;
          final prod = await products.byId(it.productId!);
          if (prod == null || !prod.trackStock) continue;
          await products.changeStock(prod.id, -it.qty, kind: 'cancel', refType: 'purchase', refId: id);
        }
        final now = DateTime.now();
        if (p.contactId != null) {
          await contacts.post(contactId: p.contactId!, kind: 'return', amount: p.total, refType: 'purchase', refId: id, date: now);
          if (p.paid > 0) {
            await contacts.post(contactId: p.contactId!, kind: 'refund', amount: -p.paid, refType: 'purchase', refId: id, date: now);
          }
        }
        if (p.paid > 0 && p.accountId != null) {
          await cash.add(
              accountId: p.accountId!,
              direction: 1,
              amount: p.paid,
              source: 'refund',
              refType: 'purchase',
              refId: id,
              contactId: p.contactId,
              note: p.refNo,
              date: now);
        }
        await (db.update(db.purchases)..where((t) => t.id.equals(id))).write(const PurchasesCompanion(status: Value('cancelled')));
      });

  Stream<List<PurchaseRow>> watchList({required DateRange range, String query = '', int? supplierId}) {
    final where = StringBuffer('p.date BETWEEN ? AND ?');
    final vars = <Variable>[Variable.withDateTime(range.from), Variable.withDateTime(range.to)];
    if (supplierId != null) {
      where.write(' AND p.contact_id = ?');
      vars.add(Variable.withInt(supplierId));
    }
    if (query.trim().isNotEmpty) {
      where.write(' AND (p.ref_no LIKE ? OR c.name LIKE ? OR p.note LIKE ?)');
      final like = '%${query.trim()}%';
      vars.addAll([like, like, like].map(Variable.withString));
    }
    return db
        .customSelect(
          '''SELECT p.*, c.name AS supplier_name,
               (SELECT COUNT(*) FROM purchase_items i WHERE i.purchase_id = p.id) AS item_count
             FROM purchases p LEFT JOIN contacts c ON c.id = p.contact_id
             WHERE $where ORDER BY p.date DESC, p.id DESC''',
          variables: vars,
          readsFrom: {db.purchases, db.contacts, db.purchaseItems},
        )
        .watch()
        .map((rows) => rows
            .map((r) => PurchaseRow(db.purchases.map(r.data), r.readNullable<String>('supplier_name'), r.read<int>('item_count')))
            .toList());
  }

  Future<PurchaseDetail?> detail(int id) async {
    final p = await (db.select(db.purchases)..where((t) => t.id.equals(id))).getSingleOrNull();
    if (p == null) return null;
    final items = await (db.select(db.purchaseItems)..where((t) => t.purchaseId.equals(id))).get();
    final sup = p.contactId == null ? null : await contacts.byId(p.contactId!);
    return PurchaseDetail(p, items, sup);
  }
}
