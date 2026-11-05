import 'package:bizkhata/core/util.dart';
import 'package:bizkhata/couriers/courier.dart';
import 'package:bizkhata/data/biz.dart';
import 'package:bizkhata/data/seed.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

Future<Biz> freshBiz({bool online = false}) async {
  final biz = Biz(AppDatabase(NativeDatabase.memory()));
  await seedBusiness(biz, name: 'Test Shop', typeId: online ? 'online' : 'grocery', bangla: false);
  if (online) await biz.settings.setJson(K.courierConfig, {'testMode': true, 'default': 'steadfast'});
  return biz;
}

Future<int> cashId(Biz b) async => (await b.cash.accounts()).first.id;

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  group('helpers', () {
    test('phone normalisation', () {
      expect(normalizePhone('+880 1711-000001'), '01711000001');
      expect(normalizePhone('8801711000001'), '01711000001');
      expect(normalizePhone('1711000001'), '01711000001');
      expect(normalizePhone('০১৭১১০০০০০১'), '01711000001');
      expect(isValidBdMobile('01211000001'), isFalse);
      expect(isValidBdMobile('01911000001'), isTrue);
    });

    test('invoice totals', () {
      final t = computeTotals(const [
        CartLine(name: 'a', qty: 3, price: 33.33),
        CartLine(name: 'b', qty: 1.5, price: 10),
      ], discount: 9.99, vatPercent: 5, deliveryCharge: 60);
      expect(t.subtotal, 114.99);
      expect(t.discount, 9.99);
      expect(t.vat, 5.25);
      expect(t.total, 170.25);
      // Discount can never exceed the subtotal.
      expect(computeTotals(const [CartLine(name: 'x', qty: 1, price: 50)], discount: 80).total, 0);
    });

    test('courier status mapping', () {
      expect(mapOutcome('delivered'), DeliveryOutcome.delivered);
      expect(mapOutcome('Delivered'), DeliveryOutcome.delivered);
      expect(mapOutcome('delivered_approval_pending'), DeliveryOutcome.inTransit);
      expect(mapOutcome('partial_delivered'), DeliveryOutcome.partial);
      expect(mapOutcome('Partial_Delivery'), DeliveryOutcome.partial);
      expect(mapOutcome('cancelled'), DeliveryOutcome.returned);
      expect(mapOutcome('Paid_Return'), DeliveryOutcome.returned);
      expect(mapOutcome('pickup-pending'), DeliveryOutcome.inTransit);
      expect(mapOutcome('In_Transit'), DeliveryOutcome.inTransit);
    });

    test('fraud score: null ratios are unknown, not clean', () {
      final s = FraudScore.fromJson({'delivery_ratio': null, 'cancellation_ratio': null, 'volume_band': 'none'});
      expect(s.unknown, isTrue);
      expect(s.risk, -1);
      final bad = FraudScore.fromJson({'delivery_ratio': 40, 'cancellation_ratio': 59, 'total_reports': 1});
      expect(bad.risk, 2);
      final good = FraudScore.fromJson({'delivery_ratio': 95, 'cancellation_ratio': 4, 'total_reports': 0});
      expect(good.risk, 0);
    });
  });

  group('stock & sales', () {
    test('opening stock is logged', () async {
      final b = await freshBiz();
      final id = await b.products.create(const ProductInput(name: 'Rice', costPrice: 50, salePrice: 60), openingStock: 10);
      expect((await b.products.byId(id))!.stock, 10);
      final moves = await b.products.watchMoves(id).first;
      expect(moves.single.kind, 'opening');
    });

    test('paid counter sale: stock down, cash in, no khata', () async {
      final b = await freshBiz();
      final pid = await b.products.create(const ProductInput(name: 'Oil', costPrice: 160, salePrice: 185), openingStock: 20);
      final acc = await cashId(b);
      final sid = await b.sales.createSale(
        lines: const [CartLine(productId: null, name: 'Bag', qty: 1, price: 15)] +
            [CartLine(productId: pid, name: 'Oil', qty: 2, price: 185)],
        paid: 385,
        accountId: acc,
      );
      expect((await b.products.byId(pid))!.stock, 18);
      expect(await b.cash.balanceOf(acc), 385);
      final s = (await b.sales.byId(sid))!;
      expect(s.invoiceNo, 'INV-1001');
      expect(s.costTotal, 320);
      final sum = await b.reports.watchSales(DateRange.today()).first;
      expect(sum.total, 385);
      expect(sum.grossProfit, 65);
    });

    test('due sale goes to the customer khata', () async {
      final b = await freshBiz();
      final acc = await cashId(b);
      final cust = await b.contacts.create(type: 'customer', name: 'Rahim', phone: '01711000001');
      await b.sales.createSale(lines: const [CartLine(name: 'Item', qty: 1, price: 1000)], contactId: cust, paid: 400, accountId: acc);
      expect(await b.contacts.balanceOf(cust), 600);
      expect(await b.cash.balanceOf(acc), 400);
      final totals = await b.contacts.watchTotals().first;
      expect(totals.receivable, 600);
    });

    test('due without a customer is refused', () async {
      final b = await freshBiz();
      final acc = await cashId(b);
      expect(
        () => b.sales.createSale(lines: const [CartLine(name: 'Item', qty: 1, price: 100)], paid: 50, accountId: acc),
        throwsA(isA<BizException>()),
      );
      // Nothing half-written: the invoice counter rolled back with the transaction.
      final s = await b.sales.createSale(lines: const [CartLine(name: 'Item', qty: 1, price: 100)], paid: 100, accountId: acc);
      expect((await b.sales.byId(s))!.invoiceNo, 'INV-1001');
    });

    test('negative stock can be blocked', () async {
      final b = await freshBiz();
      await b.settings.setFlag(K.allowNegativeStock, false);
      final pid = await b.products.create(const ProductInput(name: 'Milk', salePrice: 100), openingStock: 1);
      expect(
        () => b.sales.createSale(lines: [CartLine(productId: pid, name: 'Milk', qty: 2, price: 100)], paid: 200, accountId: 1),
        throwsA(isA<BizException>()),
      );
      expect((await b.products.byId(pid))!.stock, 1);
    });

    test('returning a sale undoes stock, khata and cash', () async {
      final b = await freshBiz();
      final acc = await cashId(b);
      final pid = await b.products.create(const ProductInput(name: 'Soap', costPrice: 40, salePrice: 55), openingStock: 10);
      final cust = await b.contacts.create(type: 'customer', name: 'Karim');
      final sid = await b.sales.createSale(
          lines: [CartLine(productId: pid, name: 'Soap', qty: 4, price: 55)], contactId: cust, paid: 100, accountId: acc);
      await b.sales.returnSale(sid);
      expect((await b.products.byId(pid))!.stock, 10);
      expect(await b.contacts.balanceOf(cust), 0);
      expect(await b.cash.balanceOf(acc), 0);
      expect((await b.sales.byId(sid))!.status, 'returned');
      expect((await b.reports.watchSales(DateRange.today()).first).count, 0);
      expect(() => b.sales.returnSale(sid), throwsA(isA<BizException>()));
    });
  });

  group('purchases', () {
    test('weighted average cost, supplier payable, cash out', () async {
      final b = await freshBiz();
      final acc = await cashId(b);
      await b.cash.manual(accountId: acc, cashIn: true, amount: 10000);
      final pid = await b.products.create(const ProductInput(name: 'Rice', costPrice: 50, salePrice: 60), openingStock: 10);
      final sup = await b.contacts.create(type: 'supplier', name: 'Al-Amin');
      final purId = await b.purchases.create(
        supplierId: sup,
        lines: [PurchaseLine(productId: pid, name: 'Rice', qty: 10, unitCost: 70, newSalePrice: 80)],
        paid: 300,
        accountId: acc,
      );
      final p = (await b.products.byId(pid))!;
      expect(p.stock, 20);
      expect(p.costPrice, 60); // (10*50 + 10*70) / 20
      expect(p.salePrice, 80);
      expect(await b.contacts.balanceOf(sup), -400); // we owe 700 - 300
      expect(await b.cash.balanceOf(acc), 9700);
      expect((await b.contacts.watchTotals().first).payable, 400);

      await b.purchases.cancel(purId);
      expect((await b.products.byId(pid))!.stock, 10);
      expect(await b.contacts.balanceOf(sup), 0);
      expect(await b.cash.balanceOf(acc), 10000);
    });

    test('bill discount lowers the average cost', () async {
      final b = await freshBiz();
      final pid = await b.products.create(const ProductInput(name: 'Tea'));
      final sup = await b.contacts.create(type: 'supplier', name: 'S');
      await b.purchases.create(
          supplierId: sup, lines: [PurchaseLine(productId: pid, name: 'Tea', qty: 10, unitCost: 100)], discount: 100, paid: 0);
      expect((await b.products.byId(pid))!.costPrice, 90);
    });
  });

  group('khata, cash, expenses', () {
    test('gave / got entries and their cash effect', () async {
      final b = await freshBiz();
      final acc = await cashId(b);
      final c = await b.contacts.create(type: 'customer', name: 'Salma', openingBalance: 500);
      await b.contacts.addEntry(contactId: c, gave: true, amount: 200); // goods on credit, no cash
      final gotId = await b.contacts.addEntry(contactId: c, gave: false, amount: 300, accountId: acc);
      expect(await b.contacts.balanceOf(c), 400);
      expect(await b.cash.balanceOf(acc), 300);
      final lines = await b.contacts.watchLedger(c).first;
      expect(lines.first.running, 400);
      await b.contacts.deleteEntry(gotId);
      expect(await b.contacts.balanceOf(c), 700);
      expect(await b.cash.balanceOf(acc), 0);
      expect(() => b.contacts.archive(c), throwsA(isA<BizException>()));
    });

    test('transfer and expenses', () async {
      final b = await freshBiz();
      final accs = await b.cash.accounts();
      final cash = accs[0].id, bkash = accs[1].id;
      await b.cash.manual(accountId: cash, cashIn: true, amount: 5000);
      await b.cash.transfer(fromId: cash, toId: bkash, amount: 1200);
      final exp = await b.expenses.add(category: 'Rent', amount: 800, accountId: bkash);
      expect(await b.cash.balanceOf(cash), 3800);
      expect(await b.cash.balanceOf(bkash), 400);
      final flow = await b.cash.watchFlow(range: DateRange.today()).first;
      expect(flow.cashIn, 5000); // transfers don't count as in/out overall
      expect(flow.cashOut, 800);
      await b.expenses.delete(exp);
      expect(await b.cash.balanceOf(bkash), 1200);
      final tx = (await b.cash.watchTxns(range: DateRange.today()).first).firstWhere((t) => t.source == 'transfer');
      await b.cash.deleteManual(tx.id);
      expect(await b.cash.balanceOf(cash), 5000);
      expect(await b.cash.balanceOf(bkash), 0);
    });
  });

  group('online orders & courier', () {
    Future<(Biz, int, int)> order({double advance = 0}) async {
      final b = await freshBiz(online: true);
      final pid = await b.products.create(const ProductInput(name: 'Watch', costPrice: 500, salePrice: 900), openingStock: 5);
      final id = await b.orders.create(
        name: 'Nusrat',
        phone: '+8801722000011',
        address: 'House 12, Dhanmondi',
        area: 'Dhanmondi',
        city: 'Dhaka',
        lines: [CartLine(productId: pid, name: 'Watch', qty: 1, price: 900)],
        deliveryCharge: 60,
        advance: advance,
        advanceAccountId: advance > 0 ? await cashId(b) : null,
      );
      return (b, id, pid);
    }

    test('order reserves stock, is not revenue until delivered', () async {
      final (b, id, pid) = await order();
      expect((await b.products.byId(pid))!.stock, 4);
      final s = (await b.sales.byId(id))!;
      expect(s.total, 960);
      expect(s.shipPhone, '01722000011');
      expect((await b.reports.watchSales(DateRange.today()).first).count, 0);
      // The customer is created automatically, but online COD never hits the khata.
      final cust = await b.contacts.byPhone('customer', '01722000011');
      expect(cust, isNotNull);
      expect(await b.contacts.balanceOf(cust!.id), 0);
    });

    test('book → delivered: COD lands in courier balance, fee is an expense', () async {
      final (b, id, _) = await order(advance: 60);
      final ship = await b.orders.book(id, 'steadfast');
      expect(ship.codAmount, 900);
      expect((await b.sales.byId(id))!.status, 'booked');
      expect(await b.orders.watchCodPending().first, 900);
      await b.orders.markDelivered(id, fee: 60);
      final s = (await b.sales.byId(id))!;
      expect(s.status, 'delivered');
      expect(s.paid, 960);
      final courierAcc = await b.cash.ensureCourierAccount();
      expect(await b.cash.balanceOf(courierAcc), 840); // 900 COD - 60 fee
      final pl = await b.reports.watchProfitLoss(DateRange.today()).first;
      expect(pl.sales.grossProfit, 460); // 900 - 500 + 60 delivery income
      expect(pl.netProfit, 400);
      expect(() => b.orders.markDelivered(id), throwsA(isA<BizException>()));
    });

    test('partial delivery turns the shortfall into discount', () async {
      final (b, id, _) = await order();
      await b.orders.book(id, 'pathao');
      await b.orders.markDelivered(id, collected: 500);
      final s = (await b.sales.byId(id))!;
      expect(s.status, 'partial');
      expect(s.total, 500);
      expect(s.discount, 460);
      expect(s.paid, 500);
    });

    test('returned order restocks and records the return charge', () async {
      final (b, id, pid) = await order();
      await b.orders.book(id, 'redx');
      await b.orders.markReturned(id, fee: 30);
      expect((await b.sales.byId(id))!.status, 'returned');
      expect((await b.products.byId(pid))!.stock, 5);
      expect(await b.reports.watchExpenseTotal(DateRange.today()).first, 30);
      final hist = await b.contacts.orderHistory('01722000011');
      expect(hist.returned, 1);
    });

    test('cancel refunds the advance when asked', () async {
      final (b, id, pid) = await order(advance: 100);
      final acc = await cashId(b);
      expect(await b.cash.balanceOf(acc), 100);
      await b.orders.cancel(id, refundAdvance: true);
      expect(await b.cash.balanceOf(acc), 0);
      expect((await b.products.byId(pid))!.stock, 5);
      expect((await b.sales.byId(id))!.status, 'cancelled');
    });

    test('status sync settles parcels the courier reports as finished', () async {
      final (b, id, _) = await order();
      await b.orders.bookManual(id); // manual parcels are skipped by sync
      final s1 = await b.orders.syncStatuses();
      expect(s1.checked, 0);
      expect((await b.sales.byId(id))!.status, 'booked');
    });
  });

  test('CSV product import creates, updates by barcode and skips blanks', () async {
    final b = await freshBiz();
    final csv = '﻿Name,Category,Unit,Cost Price,Sale Price,Stock,Barcode\r\n'
        '"Rice, Miniket 5kg",Rice,bag,340,390,40,111\r\n'
        ',,,,,,\r\n'
        'চা পাতা ৪০০ গ্রাম,Tea,packet,190,230,12,222\r\n';
    final r1 = await b.products.importCsv(parseCsv(csv));
    expect((r1.created, r1.updated, r1.skipped), (2, 0, 0));
    final rice = (await b.products.byCode('111'))!;
    expect(rice.name, 'Rice, Miniket 5kg');
    expect(rice.stock, 40);
    expect((await b.products.byCode('222'))!.name, 'চা পাতা ৪০০ গ্রাম');

    final r2 = await b.products.importCsv(parseCsv('name,sale_price,stock,barcode\nRice 5kg,400,35,111\n'));
    expect((r2.created, r2.updated), (0, 1));
    final again = (await b.products.byCode('111'))!;
    expect(again.salePrice, 400);
    expect(again.costPrice, 340); // untouched column keeps its value
    expect(again.stock, 35);
  });

  test('demo data seeds without errors and balances add up', () async {
    final b = await freshBiz();
    await seedDemoData(b, bangla: false);
    final sum = await b.reports.watchSales(DateRange.lastDays(14)).first;
    expect(sum.count, greaterThan(20));
    final balances = await b.cash.watchBalances().first;
    final cashIn = await b.db.customSelect('SELECT SUM(direction*amount) AS v FROM cash_txns').getSingle();
    expect(balances.fold<double>(0, (s, a) => s + a.balance), closeTo(cashIn.read<double>('v'), 0.01));
  });
}
