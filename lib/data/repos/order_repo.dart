import 'dart:convert';

import 'package:drift/drift.dart';

import '../../core/util.dart';
import '../../couriers/courier.dart';
import '../../couriers/registry.dart';
import '../database.dart';
import 'cash_repo.dart';
import 'contact_repo.dart';
import 'expense_repo.dart';
import 'sale_repo.dart';
import 'settings_repo.dart';

const openOrderStatuses = ['pending', 'confirmed', 'booked'];
const orderStatuses = ['pending', 'confirmed', 'booked', 'delivered', 'partial', 'returned', 'cancelled'];

class SyncSummary {
  int checked = 0;
  int delivered = 0;
  int returned = 0;
  int partial = 0;
  final errors = <String>[];

  /// Orders this sync marked delivered (for the thank-you SMS).
  final deliveredIds = <int>[];
}

class OrderRepo {
  final AppDatabase db;
  final SettingsRepo settings;
  final SaleRepo sales;
  final ContactRepo contacts;
  final CashRepo cash;
  final ExpenseRepo expenses;
  OrderRepo(this.db, this.settings, this.sales, this.contacts, this.cash, this.expenses);

  Future<CourierConfig> courierConfig() async => CourierConfig(await settings.getJson(K.courierConfig));

  /// New delivery order. Stock is reserved now; money arrives on delivery
  /// (COD) — only an advance, if any, is booked today.
  Future<int> create({
    required String name,
    required String phone,
    required String address,
    String? area,
    String? city,
    required List<CartLine> lines,
    double discount = 0,
    double deliveryCharge = 0,
    double advance = 0,
    int? advanceAccountId,
    String? note,
    DateTime? date,
  }) =>
      db.transaction(() async {
        final p = normalizePhone(phone);
        if (name.trim().isEmpty) throw BizException('name_required');
        if (!isValidBdMobile(p)) throw BizException('phone_invalid');
        if (address.trim().isEmpty) throw BizException('address_required');
        final t = computeTotals(lines, discount: discount, deliveryCharge: deliveryCharge);
        final adv = r2(advance.clamp(0, t.total));
        if (adv > 0 && advanceAccountId == null) throw BizException('account_required');
        final when = date ?? DateTime.now();
        final contactId = await contacts.findOrCreateCustomer(name: name, phone: p, address: address);
        final id = await sales.insertDocument(
          channel: 'online',
          status: 'pending',
          lines: lines,
          totals: t,
          paid: adv,
          contactId: contactId,
          accountId: advanceAccountId,
          note: note,
          date: when,
          shipName: name.trim(),
          shipPhone: p,
          shipAddress: address.trim(),
          shipArea: area?.trim().isEmpty ?? true ? null : area!.trim(),
          shipCity: city?.trim().isEmpty ?? true ? null : city!.trim(),
        );
        if (adv > 0) {
          await cash.add(
            accountId: advanceAccountId!,
            direction: 1,
            amount: adv,
            source: 'sale',
            refType: 'sale',
            refId: id,
            contactId: contactId,
            note: 'Advance',
            date: when,
          );
        }
        return id;
      });

  Future<Sale> _open(int id) async {
    final s = await sales.byId(id);
    if (s == null || s.channel != 'online') throw BizException('not_found');
    if (!openOrderStatuses.contains(s.status)) throw BizException('order_closed');
    return s;
  }

  Future<void> _setStatus(int id, String status) => (db.update(db.sales)..where((t) => t.id.equals(id)))
      .write(SalesCompanion(status: Value(status), updatedAt: Value(DateTime.now())));

  Future<void> confirm(int id) async {
    final s = await _open(id);
    if (s.status == 'pending') await _setStatus(id, 'confirmed');
  }

  Future<void> cancel(int id, {bool refundAdvance = false, int? refundAccountId}) => db.transaction(() async {
        final s = await _open(id);
        await sales.restock(id, kind: 'cancel');
        if (refundAdvance && s.paid > 0) {
          final acc = refundAccountId ?? s.accountId ?? await cash.defaultCashAccount();
          await cash.add(
              accountId: acc,
              direction: -1,
              amount: s.paid,
              source: 'refund',
              refType: 'sale',
              refId: id,
              contactId: s.contactId,
              note: 'Advance refund');
          await (db.update(db.sales)..where((t) => t.id.equals(id))).write(const SalesCompanion(paid: Value(0)));
        }
        await _setStatus(id, 'cancelled');
      });

  /// Book the parcel with a courier. The network call happens outside the
  /// transaction; only a successful booking is written.
  Future<Shipment> book(int id, String courierId, {String? note}) async {
    final s = await _open(id);
    if (s.status == 'booked') throw BizException('already_booked');
    final cfg = await courierConfig();
    if (!cfg.isConfigured(courierId)) throw BizException('courier_not_configured');
    final items = await (db.select(db.saleItems)..where((t) => t.saleId.equals(id))).get();
    final cod = r2(s.total - s.paid);
    final result = await cfg.adapter(courierId).book(BookInput(
          invoice: s.invoiceNo,
          name: s.shipName ?? '',
          phone: s.shipPhone ?? '',
          address: s.shipAddress ?? '',
          area: s.shipArea,
          city: s.shipCity,
          cod: cod,
          note: note ?? s.note,
          itemDescription: items.map((i) => '${i.name} x${_qty(i.qty)}').join(', '),
          itemCount: items.fold<double>(0, (a, i) => a + i.qty).ceil().clamp(1, 999),
        ));
    return db.transaction(() async {
      final shipId = await db.into(db.shipments).insert(ShipmentsCompanion.insert(
            saleId: id,
            courier: courierId,
            consignmentId: Value(result.consignmentId),
            trackingCode: Value(result.trackingCode),
            trackingUrl: Value(result.trackingUrl),
            courierStatus: Value(result.status),
            codAmount: Value(cod),
            fee: Value(result.fee ?? 0),
            bookedAt: DateTime.now(),
            rawJson: Value(result.raw.isEmpty ? null : result.raw),
          ));
      await _setStatus(id, 'booked');
      return (db.select(db.shipments)..where((t) => t.id.equals(shipId))).getSingle();
    });
  }

  /// Own rider / a courier without an API: record it by hand.
  Future<void> bookManual(int id, {String courier = 'manual', String? trackingCode, double fee = 0}) =>
      db.transaction(() async {
        final s = await _open(id);
        await db.into(db.shipments).insert(ShipmentsCompanion.insert(
              saleId: id,
              courier: courier,
              consignmentId: Value(trackingCode),
              trackingCode: Value(trackingCode),
              courierStatus: const Value('handed over'),
              codAmount: Value(r2(s.total - s.paid)),
              fee: Value(r2(fee)),
              bookedAt: DateTime.now(),
            ));
        await _setStatus(id, 'booked');
      });

  Future<Shipment?> lastShipment(int saleId) async {
    final rows = await (db.select(db.shipments)
          ..where((t) => t.saleId.equals(saleId))
          ..orderBy([(t) => OrderingTerm.desc(t.id)])
          ..limit(1))
        .get();
    return rows.isEmpty ? null : rows.first;
  }

  Future<int> _settlementAccount(Shipment? ship) async {
    if (ship != null && ship.courier != 'manual') return cash.ensureCourierAccount();
    return cash.defaultCashAccount();
  }

  /// Customer received the parcel. [collected] defaults to the full COD;
  /// less than that makes it a partial delivery and the shortfall becomes a
  /// discount so revenue stays true.
  Future<void> markDelivered(int id, {double? collected, double fee = 0, int? accountId}) => db.transaction(() async {
        final s = await _open(id);
        final ship = await lastShipment(id);
        final cod = r2(s.total - s.paid);
        final got = r2((collected ?? cod).clamp(0, cod));
        final acc = accountId ?? await _settlementAccount(ship);
        final shortfall = r2(cod - got);
        final now = DateTime.now();
        if (got > 0) {
          await cash.add(
              accountId: acc,
              direction: 1,
              amount: got,
              source: 'cod',
              refType: 'sale',
              refId: id,
              contactId: s.contactId,
              note: s.invoiceNo,
              date: now);
        }
        if (fee > 0) {
          await expenses.addInTx(
              category: 'Courier charge', amount: fee, accountId: acc, note: s.invoiceNo, refType: 'sale', refId: id, date: now);
        }
        await (db.update(db.sales)..where((t) => t.id.equals(id))).write(SalesCompanion(
              status: Value(shortfall > 0 ? 'partial' : 'delivered'),
              paid: Value(r2(s.paid + got)),
              discount: Value(r2(s.discount + shortfall)),
              total: Value(r2(s.total - shortfall)),
              updatedAt: Value(now),
            ));
        if (ship != null) {
          final settled = shortfall > 0 ? 'partial_delivered' : 'delivered';
          await (db.update(db.shipments)..where((t) => t.id.equals(ship.id))).write(ShipmentsCompanion(
                fee: Value(r2(fee)),
                // Keep a courier's own final wording; replace in-transit ones.
                courierStatus: mapOutcome(ship.courierStatus ?? '') == DeliveryOutcome.inTransit
                    ? Value(settled)
                    : const Value.absent(),
                updatedAt: Value(now),
              ));
        }
      });

  /// Parcel came back: goods return to stock; a return charge, if any, is an expense.
  Future<void> markReturned(int id, {double fee = 0, int? accountId}) => db.transaction(() async {
        await _open(id);
        final ship = await lastShipment(id);
        await sales.restock(id, kind: 'return');
        if (ship != null && mapOutcome(ship.courierStatus ?? '') == DeliveryOutcome.inTransit) {
          await (db.update(db.shipments)..where((t) => t.id.equals(ship.id)))
              .write(ShipmentsCompanion(courierStatus: const Value('returned'), updatedAt: Value(DateTime.now())));
        }
        if (fee > 0) {
          final acc = accountId ?? await _settlementAccount(ship);
          final s = await sales.byId(id);
          await expenses.addInTx(
              category: 'Courier return charge', amount: fee, accountId: acc, note: s?.invoiceNo, refType: 'sale', refId: id);
        }
        await _setStatus(id, 'returned');
      });

  /// Ask each courier where our booked parcels are and settle finished ones.
  Future<SyncSummary> syncStatuses({void Function(int done, int total)? onProgress}) async {
    final cfg = await courierConfig();
    final summary = SyncSummary();
    final rows = await db.customSelect(
      '''SELECT s.id AS sale_id, sh.id AS ship_id, sh.courier, sh.consignment_id, sh.fee
         FROM sales s JOIN shipments sh ON sh.id = (SELECT MAX(id) FROM shipments x WHERE x.sale_id = s.id)
         WHERE s.channel = 'online' AND s.status = 'booked' AND sh.courier <> 'manual' AND sh.consignment_id IS NOT NULL''',
      readsFrom: {db.sales, db.shipments},
    ).get();
    var done = 0;
    for (final r in rows) {
      final saleId = r.read<int>('sale_id');
      final shipId = r.read<int>('ship_id');
      final courierId = r.read<String>('courier');
      final cid = r.read<String>('consignment_id');
      final knownFee = r.read<double>('fee');
      try {
        final adapter = cfg.adapter(courierId);
        final raw = await adapter.status(cid);
        summary.checked++;
        await (db.update(db.shipments)..where((t) => t.id.equals(shipId)))
            .write(ShipmentsCompanion(courierStatus: Value(raw), updatedAt: Value(DateTime.now())));
        switch (adapter.outcome(raw)) {
          case DeliveryOutcome.delivered:
            if (cfg.autoApply) {
              await markDelivered(saleId, fee: knownFee > 0 ? knownFee : cfg.deliveryFee);
              summary.delivered++;
              summary.deliveredIds.add(saleId);
            }
          case DeliveryOutcome.returned:
            if (cfg.autoApply) {
              await markReturned(saleId, fee: cfg.returnFee);
              summary.returned++;
            }
          case DeliveryOutcome.partial:
            summary.partial++;
          case DeliveryOutcome.inTransit:
            break;
        }
      } catch (e) {
        summary.errors.add('$cid: $e');
      }
      onProgress?.call(++done, rows.length);
    }
    return summary;
  }

  /// Customer's delivery record from Steadfast, cached for 12 hours because
  /// the lookup quota is very small.
  Future<FraudScore?> fraudScore(String phone, {bool force = false}) async {
    final p = normalizePhone(phone);
    if (!isValidBdMobile(p)) throw BizException('phone_invalid');
    final cached = await (db.select(db.fraudChecks)..where((t) => t.phone.equals(p))).getSingleOrNull();
    if (!force && cached != null && DateTime.now().difference(cached.checkedAt) < const Duration(hours: 12)) {
      return FraudScore.fromJson(Map<String, dynamic>.from(jsonDecode(cached.json) as Map), checkedAt: cached.checkedAt);
    }
    final source = (await courierConfig()).fraudSource;
    if (source == null) return null;
    final score = await source.fraudScore(p);
    await db.into(db.fraudChecks).insertOnConflictUpdate(
          FraudChecksCompanion.insert(phone: p, json: jsonEncode(score.toJson()), checkedAt: score.checkedAt),
        );
    return score;
  }

  Future<FraudScore?> cachedFraudScore(String phone) async {
    final p = normalizePhone(phone);
    final cached = await (db.select(db.fraudChecks)..where((t) => t.phone.equals(p))).getSingleOrNull();
    if (cached == null) return null;
    return FraudScore.fromJson(Map<String, dynamic>.from(jsonDecode(cached.json) as Map), checkedAt: cached.checkedAt);
  }

  Stream<Map<String, int>> watchStatusCounts() => db
      .customSelect(
        "SELECT status, COUNT(*) AS n FROM sales WHERE channel = 'online' GROUP BY status",
        readsFrom: {db.sales},
      )
      .watch()
      .map((rows) => {for (final r in rows) r.read<String>('status'): r.read<int>('n')});

  /// COD still out with couriers: booked parcels' cash to collect.
  Stream<double> watchCodPending() => db
      .customSelect(
        "SELECT COALESCE(SUM(total - paid), 0) AS v FROM sales WHERE channel = 'online' AND status = 'booked'",
        readsFrom: {db.sales},
      )
      .watchSingle()
      .map((r) => r2(r.read<double>('v')));
}

String _qty(double q) => q == q.roundToDouble() ? q.toInt().toString() : q.toString();
