import 'package:bizkhata/core/util.dart';
import 'package:bizkhata/couriers/courier.dart';
import 'package:bizkhata/couriers/redx.dart';
import 'package:bizkhata/couriers/steadfast.dart';
import 'package:bizkhata/data/biz.dart';
import 'package:bizkhata/data/seed.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

Future<Biz> freshBiz() async {
  final biz = Biz(AppDatabase(NativeDatabase.memory()));
  await seedBusiness(biz, name: 'Test Shop', typeId: 'grocery', bangla: false);
  return biz;
}

Future<int> cashId(Biz b) async => (await b.cash.accounts()).first.id;

Future<(int, int)> twoProducts(Biz b) async {
  final a = await b.products.create(const ProductInput(name: 'Alpha', unit: 'pcs', salePrice: 100, costPrice: 60), openingStock: 10);
  final c = await b.products.create(const ProductInput(name: 'Beta', unit: 'pcs', salePrice: 50, costPrice: 30), openingStock: 10);
  return (a, c);
}

List<CartLine> cart(int a, int c) => [
      CartLine(productId: a, name: 'Alpha', qty: 3, price: 100),
      CartLine(productId: c, name: 'Beta', qty: 2, price: 50),
    ];

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  group('partial returns', () {
    test('returning one item splits discount and VAT and refunds cash', () async {
      final b = await freshBiz();
      final (a, c) = await twoProducts(b);
      final acc = await cashId(b);
      final cust = await b.contacts.create(type: 'customer', name: 'Rahim', phone: '01711000001');
      // subtotal 400, discount 40, VAT 5% of 360 = 18, total 378, all paid.
      final id = await b.sales.createSale(lines: cart(a, c), discount: 40, vatPercent: 5, contactId: cust, paid: 378, accountId: acc);
      final cashBefore = await b.cash.balanceOf(acc);
      final items = (await b.sales.detail(id))!.items;
      final alpha = items.firstWhere((i) => i.productId == a);

      final refund = await b.sales.returnItems(id, {alpha.id: 1}, refundAccountId: acc);
      // 100 of 400 = 25%: discount 10, VAT 4.50 → 94.50 back.
      expect(refund, 94.5);
      final s = (await b.sales.byId(id))!;
      expect(s.status, 'completed');
      expect(s.subtotal, 300);
      expect(s.discount, 30);
      expect(s.vat, 13.5);
      expect(s.total, 283.5);
      expect(s.paid, 283.5);
      expect(s.costTotal, 180); // 240 - 60
      expect((await b.products.byId(a))!.stock, 8); // 10 - 3 + 1
      expect(await b.cash.balanceOf(acc), cashBefore - 94.5);
      expect(await b.contacts.balanceOf(cust), 0);

      final d = (await b.sales.detail(id))!;
      expect(d.items.firstWhere((i) => i.productId == a).netQty, 2);
      expect(d.net.items.firstWhere((i) => i.productId == a).total, 200);

      // Reports count what is still sold.
      final top = await b.reports.watchTopProducts(DateRange.today()).first;
      expect(top.firstWhere((p) => p.name == 'Alpha').qty, 2);
      expect(top.firstWhere((p) => p.name == 'Alpha').revenue, 200);
    });

    test('returning the rest closes the sale and refunds exactly what is left', () async {
      final b = await freshBiz();
      final (a, c) = await twoProducts(b);
      final acc = await cashId(b);
      final id = await b.sales.createSale(lines: cart(a, c), discount: 40, vatPercent: 5, paid: 378, accountId: acc);
      final items = (await b.sales.detail(id))!.items;
      await b.sales.returnItems(id, {items.first.id: 1});
      final cashMid = await b.cash.balanceOf(acc);
      await b.sales.returnSale(id);
      final s = (await b.sales.byId(id))!;
      expect(s.status, 'returned');
      expect(await b.cash.balanceOf(acc), r2(cashMid - 283.5));
      expect((await b.products.byId(a))!.stock, 10);
      expect((await b.products.byId(c))!.stock, 10);
      expect(() => b.sales.returnItems(id, {items.first.id: 1}), throwsA(isA<BizException>()));
    });

    test('a return on a due sale first comes off the due', () async {
      final b = await freshBiz();
      final (a, c) = await twoProducts(b);
      final acc = await cashId(b);
      final cust = await b.contacts.create(type: 'customer', name: 'Karim', phone: '01711000002');
      final id = await b.sales.createSale(lines: cart(a, c), discount: 40, vatPercent: 5, contactId: cust, paid: 100, accountId: acc);
      expect(await b.contacts.balanceOf(cust), 278);
      final alpha = (await b.sales.detail(id))!.items.firstWhere((i) => i.productId == a);
      final cashBefore = await b.cash.balanceOf(acc);

      final pv = b.sales.previewReturn((await b.sales.byId(id))!, (await b.sales.detail(id))!.items, {alpha.id: 1});
      expect(pv.value, 94.5);
      expect(pv.refund, 0);
      expect(pv.dueCut, 94.5);

      final refund = await b.sales.returnItems(id, {alpha.id: 1});
      expect(refund, 0);
      expect(await b.cash.balanceOf(acc), cashBefore);
      expect(await b.contacts.balanceOf(cust), 183.5);
      expect((await b.sales.byId(id))!.paid, 100);
    });

    test('cannot return more than sold or nothing at all', () async {
      final b = await freshBiz();
      final (a, c) = await twoProducts(b);
      final acc = await cashId(b);
      final id = await b.sales.createSale(lines: cart(a, c), paid: 400, accountId: acc);
      final beta = (await b.sales.detail(id))!.items.firstWhere((i) => i.productId == c);
      expect(() => b.sales.returnItems(id, {beta.id: 3}),
          throwsA(isA<BizException>().having((e) => e.message, 'code', 'return_too_many')));
      expect(() => b.sales.returnItems(id, {}),
          throwsA(isA<BizException>().having((e) => e.message, 'code', 'nothing_to_return')));
      expect((await b.products.byId(c))!.stock, 8, reason: 'a rejected return changes nothing');
    });
  });

  group('courier contracts (checked against the official guides)', () {
    test('Steadfast invoices keep only letters, digits, - and _', () {
      expect(SteadfastCourier.safeInvoice('INV-1001'), 'INV-1001');
      expect(SteadfastCourier.safeInvoice('রহিম/12 34'), '-12-34');
      expect(SteadfastCourier.safeInvoice('A' * 150).length, 100);
    });

    test('RedX "paid" means delivered; returning is not yet returned', () {
      final r = RedxCourier(token: 't');
      expect(r.outcome('paid'), DeliveryOutcome.delivered);
      expect(r.outcome('delivered'), DeliveryOutcome.delivered);
      expect(r.outcome('agent-returning'), DeliveryOutcome.inTransit);
      expect(r.outcome('returned'), DeliveryOutcome.returned);
      expect(mapOutcome('exceptional'), DeliveryOutcome.inTransit, reason: 'lost/damaged needs a human');
      expect(mapOutcome('hold'), DeliveryOutcome.inTransit);
    });
  });

  group('staff', () {
    test('PINs are salted and checked', () {
      final h1 = hashStaffPin('1234');
      final h2 = hashStaffPin('1234');
      expect(h1, isNot(h2));
      expect(checkStaffPin(h1, '1234'), isTrue);
      expect(checkStaffPin(h1, '4321'), isFalse);
      expect(checkStaffPin('garbage', '1234'), isFalse);
    });

    test('add, rename, unique names, disable', () async {
      final b = await freshBiz();
      final id = await b.staff.add(name: 'Karim', role: 'cashier', pin: '1111');
      expect(() => b.staff.add(name: ' karim ', role: 'manager', pin: '2222'),
          throwsA(isA<BizException>().having((e) => e.message, 'code', 'staff_exists')));
      expect(() => b.staff.add(name: 'Short', role: 'cashier', pin: '12'),
          throwsA(isA<BizException>().having((e) => e.message, 'code', 'pin_short')));
      await b.staff.update(id, name: 'Karim Mia', role: 'manager');
      final u = (await b.staff.byId(id))!;
      expect(u.name, 'Karim Mia');
      expect(u.role, 'manager');
      expect(checkStaffPin(u.pinHash, '1111'), isTrue, reason: 'empty new PIN keeps the old one');
      await b.staff.setActive(id, false);
      expect(await b.staff.active(), isEmpty);
    });

    test('roles decide pages and actions', () {
      const owner = Actor.owner;
      final manager = Actor.staff(StaffUser(id: 1, name: 'M', pinHash: 'x', role: 'manager', active: true, createdAt: DateTime(2026)));
      final cashier = Actor.staff(StaffUser(id: 2, name: 'C', pinHash: 'x', role: 'cashier', active: true, createdAt: DateTime(2026)));
      expect(owner.can(Cap.ownerOnly), isTrue);
      expect(manager.can(Cap.ownerOnly), isFalse);
      expect(manager.can(Cap.reports), isTrue);
      expect(cashier.can(Cap.seeCost), isFalse);
      expect(cashier.can(Cap.returns), isFalse);
      expect(cashier.home, '/pos');
      expect(cashier.canVisit('/pos'), isTrue);
      expect(cashier.canVisit('/customers/4'), isTrue);
      expect(cashier.canVisit('/reports'), isFalse);
      expect(cashier.canVisit('/settings'), isFalse);
      expect(cashier.canVisit('/'), isFalse);
      expect(manager.canVisit('/settings'), isTrue);
      expect(owner.stamp, isNull);
      expect(cashier.stamp, 'C');
    });

    test('what a staff member records carries their name', () async {
      final b = await freshBiz();
      final (a, c) = await twoProducts(b);
      final acc = await cashId(b);
      b.db.actor = 'Karim';
      final id = await b.sales.createSale(lines: cart(a, c), paid: 400, accountId: acc);
      await b.expenses.add(category: 'Rent', amount: 500, accountId: acc);
      expect((await b.sales.byId(id))!.createdBy, 'Karim');
      final txns = await b.db.select(b.db.cashTxns).get();
      expect(txns.every((t) => t.createdBy == 'Karim'), isTrue);
      final ex = await b.db.select(b.db.expenses).get();
      expect(ex.single.createdBy, 'Karim');
      b.db.actor = null;
      final id2 = await b.sales.createSale(lines: cart(a, c), paid: 400, accountId: acc);
      expect((await b.sales.byId(id2))!.createdBy, isNull);
    });
  });
}
