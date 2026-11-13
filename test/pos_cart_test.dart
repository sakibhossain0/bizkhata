import 'dart:io';

import 'package:bizkhata/app.dart';
import 'package:bizkhata/core/format.dart';
import 'package:bizkhata/core/i18n.dart';
import 'package:bizkhata/core/util.dart';
import 'package:bizkhata/data/biz.dart';
import 'package:bizkhata/data/business_store.dart';
import 'package:bizkhata/data/seed.dart';
import 'package:bizkhata/services/templates.dart';
import 'package:bizkhata/state/app_state.dart';
import 'package:drift/drift.dart' show Variable, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

Future<Biz> _shop() async {
  final biz = Biz(AppDatabase(NativeDatabase.memory()));
  await seedBusiness(biz, name: 'Shop', typeId: 'grocery', bangla: false);
  return biz;
}

Future<int> _cash(Biz b) async => (await b.cash.accounts()).first.id;

Future<List<({int dir, double amount})>> _cashFor(Biz b, int saleId) async {
  final rows = await b.db.customSelect(
    "SELECT direction, amount FROM cash_txns WHERE ref_type = 'sale' AND ref_id = ?",
    variables: [Variable.withInt(saleId)],
  ).get();
  return [for (final r in rows) (dir: r.read<int>('direction'), amount: r.read<double>('amount'))];
}

class _ReadyController extends AppController {
  final Session s;
  _ReadyController(this.s);
  @override
  AppPhase build() => Ready(s);
}

Future<void> _loadFont(String family, List<String> files) async {
  final loader = FontLoader(family);
  for (final f in files) {
    loader.addFont(Future.value(ByteData.view(Uint8List.fromList(File(f).readAsBytesSync()).buffer)));
  }
  await loader.load();
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  group('counter sale with delivery and due', () {
    test('the delivery charge is part of the total; the cash entry is what was paid', () async {
      final b = await _shop();
      final acc = await _cash(b);
      final id = await b.sales.createSale(
        lines: const [CartLine(name: 'Rice', qty: 2, price: 100)],
        discount: 20,
        vatPercent: 5,
        deliveryCharge: 60,
        paid: 249,
        accountId: acc,
      );
      final s = (await b.sales.byId(id))!;
      expect(s.subtotal, 200);
      expect(s.deliveryCharge, 60);
      expect(s.total, 249); // 200 - 20 discount + 9 VAT (delivery is not taxed) + 60 delivery
      expect(s.paid, 249);
      expect(await _cashFor(b, id), [(dir: 1, amount: 249.0)]);
      expect(await b.cash.balanceOf(acc), 249);
      final sum = await b.reports.watchSales(DateRange.today()).first;
      expect(sum.total, 249);
    });

    test('a sale left fully due puts the whole total on the customer khata', () async {
      final b = await _shop();
      final cust = await b.contacts.create(type: 'customer', name: 'Rahim', phone: '01711000001');
      final id = await b.sales.createSale(
        lines: const [CartLine(name: 'Oil', qty: 1, price: 185)],
        deliveryCharge: 50,
        contactId: cust,
        paid: 0,
      );
      final s = (await b.sales.byId(id))!;
      expect(s.total, 235);
      expect(s.paid, 0);
      expect(s.accountId, isNull);
      expect(await b.contacts.balanceOf(cust), s.total);
      expect(await _cashFor(b, id), isEmpty);
      for (final a in await b.cash.accounts()) {
        expect(await b.cash.balanceOf(a.id), 0);
      }
    });

    test('a part payment goes to the account, the rest to the khata', () async {
      final b = await _shop();
      final acc = await _cash(b);
      final cust = await b.contacts.create(type: 'customer', name: 'Karim', openingBalance: 100);
      final id = await b.sales.createSale(
        lines: const [CartLine(name: 'Item', qty: 1, price: 1000)],
        deliveryCharge: 100,
        contactId: cust,
        paid: 400,
        accountId: acc,
      );
      expect((await b.sales.byId(id))!.total, 1100);
      expect(await b.contacts.balanceOf(cust), 800); // 100 old + 1100 - 400
      expect(await b.cash.balanceOf(acc), 400);
      final kinds = (await b.contacts.watchLedger(cust).first).map((l) => (l.entry.kind, l.entry.amount)).toList();
      expect(kinds, containsAll([('sale', 1100.0), ('payment', -400.0)]));
    });
  });

  group('customer typed at the till', () {
    test('a known phone reuses that customer, a new phone saves a new one', () async {
      final b = await _shop();
      final rahim = await b.contacts.create(type: 'customer', name: 'Rahim', phone: '01711000001');
      expect(await b.contacts.customerFor(name: 'Someone else', phone: '+880 1711-000001'), rahim);
      expect((await b.contacts.byId(rahim))!.name, 'Rahim', reason: 'an existing customer is never renamed');

      final karim = await b.contacts.customerFor(name: ' Karim ', phone: '01811000002');
      expect(karim, isNot(rahim));
      final k = (await b.contacts.byId(karim))!;
      expect((k.type, k.name, k.phone), ('customer', 'Karim', '01811000002'));

      // A phone alone names the customer after the number.
      final noName = (await b.contacts.byId(await b.contacts.customerFor(phone: '01911000003')))!;
      expect((noName.name, noName.phone), ('01911000003', '01911000003'));

      // A supplier with the same number is not a customer.
      final sup = await b.contacts.create(type: 'supplier', name: 'Supplier', phone: '01611000004');
      final buyer = await b.contacts.customerFor(name: 'Buyer', phone: '01611000004');
      expect(buyer, isNot(sup));
      expect((await b.contacts.byId(buyer))!.type, 'customer');
    });

    test('a name alone reuses the same name (any case, outer spaces), else saves a new one', () async {
      final b = await _shop();
      final karim = await b.contacts.create(type: 'customer', name: 'Karim Uddin', phone: '01711000009');
      expect(await b.contacts.customerFor(name: '  karim uddin '), karim);
      expect(await b.contacts.customerFor(name: 'KARIM UDDIN'), karim);
      final bn = await b.contacts.create(type: 'customer', name: 'রহিম মিয়া');
      expect(await b.contacts.customerFor(name: 'রহিম মিয়া '), bn);

      // Archived customers and suppliers are not reused.
      final old = await b.contacts.create(type: 'customer', name: 'Old Friend');
      await b.contacts.archive(old);
      expect(await b.contacts.customerFor(name: 'Old Friend'), isNot(old));
      final sup = await b.contacts.create(type: 'supplier', name: 'Al-Amin');
      expect(await b.contacts.customerFor(name: 'Al-Amin'), isNot(sup));

      final salma = await b.contacts.customerFor(name: 'Salma');
      final s = (await b.contacts.byId(salma))!;
      expect((s.type, s.name, s.phone), ('customer', 'Salma', null));
      expect(await b.contacts.customerFor(name: 'salma'), salma);
    });

    test('neither a name nor a phone is refused', () async {
      final b = await _shop();
      final named = isA<BizException>().having((e) => e.message, 'code', 'name_required');
      await expectLater(b.contacts.customerFor(), throwsA(named));
      await expectLater(b.contacts.customerFor(name: '  ', phone: ' - '), throwsA(named));
    });

    test('a name several customers share picks none: the till must be told which', () async {
      final b = await _shop();
      final first = await b.contacts.create(type: 'customer', name: 'Rahim', phone: '01711000001');
      await b.contacts.create(type: 'customer', name: 'rahim ', phone: '01911000002');
      final both = await b.contacts.customerByName(' RAHIM');
      expect((both.contact, both.ambiguous), (null, true));
      final ambiguous = isA<BizException>().having((e) => e.message, 'code', 'name_ambiguous');
      await expectLater(b.contacts.customerFor(name: 'Rahim'), throwsA(ambiguous));
      // The phone still tells them apart, and nothing new was saved.
      expect(await b.contacts.customerFor(name: 'Rahim', phone: '01711000001'), first);
      expect((await b.db.select(b.db.contacts).get()).length, 2);

      // One customer under a name is still found; an archived namesake doesn't count.
      final karim = await b.contacts.create(type: 'customer', name: 'Karim');
      await b.contacts.archive(await b.contacts.create(type: 'customer', name: 'Karim'));
      final one = await b.contacts.customerByName('karim');
      expect((one.contact?.id, one.ambiguous), (karim, false));
      expect(await b.contacts.customerFor(name: 'Karim'), karim);
    });

    test('setPhone saves only the number, and refuses one another customer has', () async {
      final b = await _shop();
      final salma = await b.contacts.create(
          type: 'customer', name: 'Salma', address: 'Mirpur 10', email: 'salma@example.com', note: 'Pays on Fridays');
      final rahim = await b.contacts.create(type: 'customer', name: 'Rahim', phone: '01711000001');
      await b.contacts.setPhone(salma, '+880 1811-000002');
      final s = (await b.contacts.byId(salma))!;
      expect((s.name, s.phone, s.address, s.email, s.note),
          ('Salma', '01811000002', 'Mirpur 10', 'salma@example.com', 'Pays on Fridays'));

      final taken = isA<BizException>().having((e) => e.message, 'code', 'phone_exists');
      await expectLater(b.contacts.setPhone(salma, '01711000001'), throwsA(taken));
      expect((await b.contacts.byId(salma))!.phone, '01811000002');
      await b.contacts.setPhone(rahim, '01711000001'); // its own number again is fine

      // A supplier's number is not a customer's.
      await b.contacts.create(type: 'supplier', name: 'Supplier', phone: '01611000004');
      await b.contacts.setPhone(salma, '01611000004');
      expect((await b.contacts.byId(salma))!.phone, '01611000004');
      final invalid = isA<BizException>().having((e) => e.message, 'code', 'phone_invalid');
      await expectLater(b.contacts.setPhone(salma, ' - '), throwsA(invalid));
    });

    test('the shared receipt text carries the delivery charge', () {
      currentLang = Lang.en;
      const text = 'Dear Rahim\nInvoice INV-1001\n• Rice × 2 = ৳200\nTotal ৳260 · Paid ৳0 · Due ৳260';
      expect(withDeliveryLine(text, 0), text);
      expect(withDeliveryLine(text, 60).split('\n'), [
        'Dear Rahim',
        'Invoice INV-1001',
        '• Rice × 2 = ৳200',
        '• ${T.deliveryCharge.s} = ৳60',
        'Total ৳260 · Paid ৳0 · Due ৳260',
      ]);
      // The shop's own message without an item list: the line goes at the end.
      expect(withDeliveryLine('Thanks!', 60), 'Thanks!\n${T.deliveryCharge.s}: ৳60');
    });
  });

  group('POS cart screen', () {
    setUpAll(() async {
      await initializeDateFormatting('en');
      await initializeDateFormatting('bn');
      // Real fonts, so text measures like in the app (the test font is much wider).
      await _loadFont('HindSiliguri', [
        for (final w in ['Light', 'Regular', 'Medium', 'SemiBold', 'Bold']) 'assets/fonts/HindSiliguri-$w.ttf',
      ]);
      await _loadFont('Bricolage', ['assets/fonts/BricolageGrotesque.ttf']);
    });

    Future<void> settle(WidgetTester tester) async {
      for (var i = 0; i < 3; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
        await tester.pump(const Duration(milliseconds: 300));
      }
    }

    Future<void> openPos(WidgetTester tester, Biz biz, Size size, Lang lang) async {
      currentLang = lang;
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final session = Session(BusinessInfo(id: 't', name: 'Shop', type: 'grocery', createdAt: DateTime.now()), biz);
      await tester.pumpWidget(ProviderScope(
        overrides: [appProvider.overrideWith(() => _ReadyController(session))],
        child: const BizKhataApp(),
      ));
      appRouter.go('/pos');
      await settle(tester);
    }

    Future<void> closeApp(WidgetTester tester, Biz biz) async {
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 1));
      await tester.runAsync(() => biz.db.close());
    }

    String fieldText(WidgetTester tester, String key) => tester
        .widget<EditableText>(find.descendant(of: find.byKey(ValueKey(key)), matching: find.byType(EditableText)))
        .controller
        .text;

    /// Brings [f] into view. The phone cart page builds only the rows near the
    /// screen, so on a long cart it is scrolled down until [f] is built.
    Future<void> scrollTo(WidgetTester tester, Finder f) async {
      final page = find.byKey(const ValueKey('pos-cart-page'));
      if (f.evaluate().isEmpty && page.evaluate().isNotEmpty) {
        await tester.scrollUntilVisible(f, 200, scrollable: find.descendant(of: page, matching: find.byType(Scrollable)).first);
      }
      await tester.ensureVisible(f);
      await tester.pump();
    }

    Future<void> tapVisible(WidgetTester tester, Finder f) async {
      await scrollTo(tester, f);
      await tester.tap(f);
      await settle(tester);
    }

    bool focused(WidgetTester tester, String key) =>
        tester.widget<TextField>(find.byKey(ValueKey(key))).focusNode!.hasFocus;

    /// Built and inside the screen, not just kept somewhere in the list.
    bool onScreen(WidgetTester tester, String key) {
      final f = find.byKey(ValueKey(key));
      if (f.evaluate().isEmpty) return false;
      final r = tester.getRect(f);
      final screen = Offset.zero & tester.view.physicalSize / tester.view.devicePixelRatio;
      return screen.contains(r.topLeft) && screen.contains(r.bottomRight - const Offset(1, 1));
    }

    Future<(List<Sale>, List<Contact>)> saved(WidgetTester tester, Biz biz) async {
      late (List<Sale>, List<Contact>) out;
      await tester.runAsync(() async => out = (await biz.db.select(biz.db.sales).get(), await biz.db.select(biz.db.contacts).get()));
      return out;
    }

    Future<void> closeDone(WidgetTester tester) async {
      await tester.tap(find.descendant(of: find.byType(Dialog), matching: find.byType(FilledButton)));
      await settle(tester);
    }

    /// Lets an error toast run out: on a phone it covers the bottom of the cart page.
    Future<void> toastGone(WidgetTester tester) async {
      await tester.pump(const Duration(seconds: 5));
      await settle(tester);
    }

    for (final lang in Lang.values) {
      testWidgets('desktop 1280x680 (${lang.name}): a known phone links the customer, Due puts the bill with delivery on khata',
          (tester) async {
        final biz = Biz(AppDatabase(NativeDatabase.memory()));
        late int rahim;
        await tester.runAsync(() async {
          await seedBusiness(biz, name: 'Shop', typeId: 'grocery', bangla: lang == Lang.bn);
          await biz.products.create(const ProductInput(name: 'Miniket Rice', costPrice: 340, salePrice: 390), openingStock: 40);
          rahim = await biz.contacts.create(type: 'customer', name: 'Rahim', phone: '01711000001', openingBalance: 100);
        });
        await openPos(tester, biz, const Size(1280, 680), lang);

        await tester.tap(find.text('Miniket Rice').first);
        await settle(tester);

        // The number finds Rahim: linked, name filled in, balance shown.
        await tester.enterText(find.byKey(const ValueKey('pos-customer-phone')), '01711000001');
        await settle(tester);
        expect(fieldText(tester, 'pos-customer-name'), 'Rahim');
        expect(find.textContaining(T.willGet.s), findsOneWidget);

        // Another number is someone else: unlinked, and the filled-in name goes with it.
        await tester.enterText(find.byKey(const ValueKey('pos-customer-phone')), '01711000002');
        await settle(tester);
        expect(fieldText(tester, 'pos-customer-name'), '');
        expect(find.text(T.posNewCustomer.s), findsOneWidget);
        await tester.enterText(find.byKey(const ValueKey('pos-customer-phone')), '01711000001');
        await settle(tester);
        expect(find.textContaining(T.willGet.s), findsOneWidget);

        await tester.enterText(find.byKey(const ValueKey('pos-delivery')), '60');
        await settle(tester);
        expect(find.text(T.deliveryCharge.s), findsOneWidget);

        await tapVisible(tester, find.byKey(const ValueKey('pos-due')));
        expect(find.textContaining(T.received.s), findsNothing, reason: 'nothing is received in Due mode');
        expect(find.text(T.dueToKhata.s), findsOneWidget);
        // Everything still fits the owner's short screen.
        expect(tester.getRect(find.text(T.completeSale.s)).bottom, lessThan(680));

        await tapVisible(tester, find.text(T.completeSale.s));
        expect(find.text(T.saleDone.s), findsOneWidget);
        late Sale s;
        late double balance;
        await tester.runAsync(() async {
          s = (await biz.db.select(biz.db.sales).get()).single;
          balance = await biz.contacts.balanceOf(rahim);
        });
        expect((s.total, s.deliveryCharge, s.paid, s.accountId, s.contactId), (450.0, 60.0, 0.0, null, rahim));
        expect(balance, 550); // 100 owed before + the whole 450

        await tester.tap(find.descendant(of: find.byType(Dialog), matching: find.byType(FilledButton)));
        await settle(tester);
        expect(fieldText(tester, 'pos-customer-phone'), '');
        expect(fieldText(tester, 'pos-delivery'), '');
        await closeApp(tester, biz);
      });

      testWidgets('phone 390x844 (${lang.name}): a refused sale brings the field back on a long cart; a typed name saves a new customer',
          (tester) async {
        final biz = Biz(AppDatabase(NativeDatabase.memory()));
        const names = ['Soybean Oil', 'Miniket Rice', 'Red Lentils', 'Sugar', 'Tea', 'Biscuits', 'Detergent', 'Bath Soap'];
        await tester.runAsync(() async {
          await seedBusiness(biz, name: 'Shop', typeId: 'grocery', bangla: lang == Lang.bn);
          for (final n in names) {
            await biz.products.create(ProductInput(name: n, costPrice: 80, salePrice: 100), openingStock: 60);
          }
        });
        await openPos(tester, biz, const Size(390, 844), lang);

        for (final n in names) {
          await tapVisible(tester, find.text(n).first);
        }
        await tester.tap(find.text(T.cart.s).first);
        await settle(tester);

        await tapVisible(tester, find.byKey(const ValueKey('pos-due')));
        expect(find.text(T.e_due_needs_customer.s), findsOneWidget);
        expect(onScreen(tester, 'pos-customer-name'), isFalse, reason: 'eight lines push the fields far up');
        await tapVisible(tester, find.text(T.completeSale.s));
        expect((await saved(tester, biz)).$1, isEmpty, reason: 'a walk-in cannot leave money due');
        expect(onScreen(tester, 'pos-customer-name'), isTrue);
        expect(focused(tester, 'pos-customer-name'), isTrue);
        await toastGone(tester);

        await tester.enterText(find.byKey(const ValueKey('pos-customer-name')), 'Karim Mia');
        await tester.enterText(find.byKey(const ValueKey('pos-customer-phone')), '01711');
        await settle(tester);
        expect(find.text(T.posNewCustomer.s), findsOneWidget);
        // The cashier moves on and the keyboard closes; the half-typed number stays.
        FocusManager.instance.primaryFocus?.unfocus();
        await scrollTo(tester, find.text(T.dueToKhata.s));
        expect(onScreen(tester, 'pos-customer-phone'), isFalse);
        await tapVisible(tester, find.text(T.completeSale.s));
        expect(find.text(T.e_phone_invalid.s), findsOneWidget);
        expect((await saved(tester, biz)).$1, isEmpty);
        expect(onScreen(tester, 'pos-customer-phone'), isTrue);
        expect(focused(tester, 'pos-customer-phone'), isTrue);
        await toastGone(tester);

        await tester.enterText(find.byKey(const ValueKey('pos-customer-phone')), '');
        await settle(tester);
        await tapVisible(tester, find.text(T.completeSale.s));
        expect(find.text(T.saleDone.s), findsOneWidget);
        late Sale s;
        late Contact karim;
        late double balance;
        await tester.runAsync(() async {
          s = (await biz.db.select(biz.db.sales).get()).single;
          karim = (await biz.contacts.byId(s.contactId!))!;
          balance = await biz.contacts.balanceOf(karim.id);
        });
        expect((karim.name, karim.phone, karim.type), ('Karim Mia', null, 'customer'));
        expect((s.total, s.paid), (800.0, 0.0));
        expect(balance, 800);
        await closeApp(tester, biz);
      });
    }

    testWidgets('a part payment still works, and the x makes it a walk-in sale again', (tester) async {
      final biz = Biz(AppDatabase(NativeDatabase.memory()));
      late int salma;
      late int cash;
      await tester.runAsync(() async {
        await seedBusiness(biz, name: 'Shop', typeId: 'grocery', bangla: false);
        await biz.products.create(const ProductInput(name: 'Tea 400g', costPrice: 190, salePrice: 230), openingStock: 24);
        salma = await biz.contacts.create(type: 'customer', name: 'Salma Begum');
        cash = await biz.cash.defaultCashAccount();
      });
      await openPos(tester, biz, const Size(1366, 768), Lang.en);
      await tester.tap(find.text('Tea 400g').first);
      await settle(tester);

      // An exact saved name links too, while no phone is typed.
      await tester.enterText(find.byKey(const ValueKey('pos-customer-name')), 'salma begum');
      await settle(tester);
      expect(find.textContaining('Salma Begum'), findsOneWidget);
      await tapVisible(tester, find.byKey(const ValueKey('pos-customer-remove')));
      expect(fieldText(tester, 'pos-customer-name'), '');
      expect(find.text(T.posNewCustomer.s), findsNothing);

      await tester.enterText(find.byKey(const ValueKey('pos-customer-name')), 'Salma Begum');
      await settle(tester);
      await tester.enterText(find.widgetWithText(TextField, '${T.received.s} (৳230)'), '100');
      await settle(tester);
      expect(find.text(T.dueToKhata.s), findsOneWidget);
      await tapVisible(tester, find.text(T.completeSale.s));
      late Sale s;
      late double balance;
      await tester.runAsync(() async {
        s = (await biz.db.select(biz.db.sales).get()).single;
        balance = await biz.contacts.balanceOf(salma);
      });
      expect((s.total, s.paid, s.accountId, s.contactId), (230.0, 100.0, cash, salma));
      expect(balance, 130);
      await closeApp(tester, biz);
    });

    testWidgets('Saved customers: the picked customer gets the sale; one with no number gets the typed one', (tester) async {
      final biz = Biz(AppDatabase(NativeDatabase.memory()));
      late int rahim;
      late int salma;
      await tester.runAsync(() async {
        await seedBusiness(biz, name: 'Shop', typeId: 'grocery', bangla: false);
        await biz.products.create(const ProductInput(name: 'Tea 400g', costPrice: 190, salePrice: 230), openingStock: 24);
        rahim = await biz.contacts.create(type: 'customer', name: 'Rahim', phone: '01711000001');
        salma = await biz.contacts.create(
            type: 'customer', name: 'Salma Begum', address: 'Mirpur 10', note: 'Pays on Fridays', openingBalance: 50);
      });
      await openPos(tester, biz, const Size(1366, 768), Lang.en);
      Future<void> pick(String name) async {
        await tester.tap(find.descendant(of: find.byType(Dialog), matching: find.text(name)));
        await settle(tester);
      }

      // F12 opens the list; picking fills both fields and shows the number.
      await tester.tap(find.text('Tea 400g').first);
      await settle(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.f12);
      await settle(tester);
      expect(find.text(T.selectCustomer.s), findsOneWidget);
      await pick('Rahim');
      expect((fieldText(tester, 'pos-customer-name'), fieldText(tester, 'pos-customer-phone')), ('Rahim', '01711000001'));
      expect(find.textContaining('Rahim  ·  01711000001'), findsOneWidget);
      await tapVisible(tester, find.byKey(const ValueKey('pos-due')));
      await tapVisible(tester, find.text(T.completeSale.s));
      expect(find.text(T.saleDone.s), findsOneWidget);
      var (sales, contacts) = await saved(tester, biz);
      expect((sales.single.contactId, contacts.length), (rahim, 2));
      await closeDone(tester);

      // Salma has no number yet. One that is already Rahim's means this is Rahim.
      await tester.tap(find.text('Tea 400g').first);
      await settle(tester);
      await tester.tap(find.byTooltip('${T.posSavedCustomers.s} · F12'));
      await settle(tester);
      await pick('Salma Begum');
      expect((fieldText(tester, 'pos-customer-name'), fieldText(tester, 'pos-customer-phone')), ('Salma Begum', ''));
      await tester.enterText(find.byKey(const ValueKey('pos-customer-phone')), '01711000001');
      await settle(tester);
      expect(fieldText(tester, 'pos-customer-name'), 'Rahim');
      expect(find.textContaining('Rahim  ·  01711000001'), findsOneWidget);

      // A number nobody has stays with Salma and is saved on her, not on a new customer.
      await tapVisible(tester, find.byKey(const ValueKey('pos-customer-remove')));
      await tester.sendKeyEvent(LogicalKeyboardKey.f12);
      await settle(tester);
      await pick('Salma Begum');
      await tester.enterText(find.byKey(const ValueKey('pos-customer-phone')), '01811000002');
      await settle(tester);
      expect(fieldText(tester, 'pos-customer-name'), 'Salma Begum');
      expect(find.textContaining(T.posAddPhone.f({'x': 'Salma Begum'})), findsOneWidget);
      await tapVisible(tester, find.byKey(const ValueKey('pos-due')));
      await tapVisible(tester, find.text(T.completeSale.s));
      expect(find.text(T.saleDone.s), findsOneWidget);
      (sales, contacts) = await saved(tester, biz);
      expect((sales.length, sales.last.contactId, contacts.length), (2, salma, 2));
      final s = contacts.firstWhere((c) => c.id == salma);
      expect((s.name, s.phone, s.address, s.note), ('Salma Begum', '01811000002', 'Mirpur 10', 'Pays on Fridays'));
      late double balance;
      await tester.runAsync(() async => balance = await biz.contacts.balanceOf(salma));
      expect(balance, 280); // 50 owed before + 230
      await closeApp(tester, biz);
    });

    testWidgets('a half-typed or 10-digit mobile number is refused before anything is saved', (tester) async {
      final biz = Biz(AppDatabase(NativeDatabase.memory()));
      await tester.runAsync(() async {
        await seedBusiness(biz, name: 'Shop', typeId: 'grocery', bangla: false);
        await biz.products.create(const ProductInput(name: 'Sugar 1kg', costPrice: 118, salePrice: 130), openingStock: 50);
      });
      await openPos(tester, biz, const Size(1366, 768), Lang.en);
      await tester.tap(find.text('Sugar 1kg').first);
      await settle(tester);
      await tester.enterText(find.byKey(const ValueKey('pos-customer-name')), 'Karim');
      await tapVisible(tester, find.byKey(const ValueKey('pos-due')));

      // Short, one digit short, one digit too many, and one short without the 0.
      for (final bad in ['01711', '0171100000', '017110000011', '171100000']) {
        await tester.enterText(find.byKey(const ValueKey('pos-customer-phone')), bad);
        await settle(tester);
        await tester.tap(find.byKey(const ValueKey('pos-customer-name'))); // the cursor is elsewhere
        await tapVisible(tester, find.text(T.completeSale.s));
        expect(find.text(T.e_phone_invalid.s), findsOneWidget, reason: bad);
        expect(focused(tester, 'pos-customer-phone'), isTrue, reason: bad);
        final (sales, contacts) = await saved(tester, biz);
        expect((sales.length, contacts.length), (0, 0), reason: bad);
      }

      // A landline's nine digits is a whole number.
      await tester.enterText(find.byKey(const ValueKey('pos-customer-phone')), '02-9876543');
      await settle(tester);
      await tapVisible(tester, find.text(T.completeSale.s));
      expect(find.text(T.saleDone.s), findsOneWidget);
      final (sales, contacts) = await saved(tester, biz);
      expect(sales.single.contactId, contacts.single.id);
      expect((contacts.single.name, contacts.single.phone), ('Karim', '029876543'));
      await closeApp(tester, biz);
    });

    testWidgets('a name two customers share links neither; Complete asks which one', (tester) async {
      final biz = Biz(AppDatabase(NativeDatabase.memory()));
      late int first;
      late int second;
      await tester.runAsync(() async {
        await seedBusiness(biz, name: 'Shop', typeId: 'grocery', bangla: false);
        await biz.products.create(const ProductInput(name: 'Sugar 1kg', costPrice: 118, salePrice: 130), openingStock: 50);
        first = await biz.contacts.create(type: 'customer', name: 'Rahim', phone: '01711000001', openingBalance: 100);
        second = await biz.contacts.create(type: 'customer', name: 'Rahim', phone: '01911000002');
      });
      await openPos(tester, biz, const Size(1366, 768), Lang.en);
      await tester.tap(find.text('Sugar 1kg').first);
      await settle(tester);

      await tester.enterText(find.byKey(const ValueKey('pos-customer-name')), 'rahim');
      await settle(tester);
      expect(find.text(T.posNameAmbiguous.s), findsOneWidget);
      expect(find.byKey(const ValueKey('pos-customer-remove')), findsNothing, reason: 'nobody is linked');
      await tapVisible(tester, find.byKey(const ValueKey('pos-due')));
      await tapVisible(tester, find.text(T.completeSale.s));
      expect(find.text(T.e_name_ambiguous.s), findsOneWidget);
      expect(find.text(T.selectCustomer.s), findsOneWidget, reason: 'the list opens to pick one');
      var (sales, contacts) = await saved(tester, biz);
      expect((sales.length, contacts.length), (0, 2));

      // The list shows each one's number.
      await tester.tap(find.descendant(of: find.byType(Dialog), matching: find.text('01911000002')));
      await settle(tester);
      expect(find.textContaining('Rahim  ·  01911000002'), findsOneWidget);
      await tapVisible(tester, find.text(T.completeSale.s));
      expect(find.text(T.saleDone.s), findsOneWidget);
      (sales, contacts) = await saved(tester, biz);
      expect((sales.single.contactId, contacts.length), (second, 2));
      late (double, double) balances;
      await tester.runAsync(() async => balances = (await biz.contacts.balanceOf(first), await biz.contacts.balanceOf(second)));
      expect(balances, (100.0, 130.0));
      await closeApp(tester, biz);
    });

    testWidgets('F9 and Ctrl+Enter each complete a cash sale', (tester) async {
      final biz = Biz(AppDatabase(NativeDatabase.memory()));
      late int cash;
      await tester.runAsync(() async {
        await seedBusiness(biz, name: 'Shop', typeId: 'grocery', bangla: false);
        await biz.products.create(const ProductInput(name: 'Biscuits', costPrice: 85, salePrice: 110), openingStock: 48);
        cash = await biz.cash.defaultCashAccount();
      });
      await openPos(tester, biz, const Size(1366, 768), Lang.en);

      await tester.tap(find.text('Biscuits').first);
      await settle(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.f9);
      await settle(tester);
      expect(find.text(T.saleDone.s), findsOneWidget);
      await closeDone(tester);

      await tester.tap(find.text('Biscuits').first);
      await settle(tester);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await settle(tester);
      expect(find.text(T.saleDone.s), findsOneWidget);

      final (sales, _) = await saved(tester, biz);
      expect([for (final s in sales) (s.total, s.paid, s.accountId, s.contactId)], [
        (110.0, 110.0, cash, null),
        (110.0, 110.0, cash, null),
      ]);
      await closeApp(tester, biz);
    });

    // The owner's short laptop screen, and a smaller one, with every row the panel can show.
    for (final (lang, size) in [(Lang.bn, const Size(1280, 680)), (Lang.en, const Size(1024, 660))]) {
      testWidgets('desktop ${size.width.toInt()}x${size.height.toInt()} (${lang.name}), six accounts, every total row: '
          'the cart list stays usable', (tester) async {
        final biz = Biz(AppDatabase(NativeDatabase.memory()));
        const items = [('Miniket Rice', 390.0), ('Soybean Oil', 185.0), ('Red Lentils', 135.0)];
        late int rahim;
        await tester.runAsync(() async {
          await seedBusiness(biz, name: 'Shop', typeId: 'grocery', bangla: lang == Lang.bn);
          await biz.cash.createAccount('Rocket', kind: 'mobile');
          await biz.cash.createAccount('City Bank Card', kind: 'card');
          for (final (name, price) in items) {
            await biz.products.create(ProductInput(name: name, costPrice: price - 30, salePrice: price), openingStock: 40);
          }
          rahim = await biz.contacts.create(type: 'customer', name: 'Rahim', phone: '01711000001', openingBalance: 100);
        });
        await openPos(tester, biz, size, lang);
        for (final (name, _) in items) {
          await tester.tap(find.text(name).first);
          await settle(tester);
        }

        // Linked customer, discount, delivery, VAT and change to give back.
        await tester.enterText(find.byKey(const ValueKey('pos-customer-phone')), '01711000001');
        await tester.enterText(find.widgetWithText(TextField, T.discount.s), '10');
        await tester.enterText(find.byKey(const ValueKey('pos-delivery')), '60');
        await tester.enterText(find.widgetWithText(TextField, T.vatPct.s), '5');
        await settle(tester);
        // 710 - 10 + 35 VAT + 60 delivery
        await tester.enterText(find.widgetWithText(TextField, '${T.received.s} (${money(795)})'), '1000');
        await settle(tester);
        expect(find.textContaining(T.willGet.s), findsOneWidget);
        expect(find.text(T.changeDue.s), findsOneWidget);
        expect(tester.takeException(), isNull, reason: 'nothing overflows');

        // Each cart line can be seen whole: the list never shrinks below one.
        final list = tester.getRect(find.byKey(const ValueKey('pos-cart-list')));
        // The panel scrolls only by what the list is short of its 110 px, so the
        // total and Complete stay near the bottom of the screen however long the cart.
        final panel = tester.state<ScrollableState>(
            find.ancestor(of: find.byKey(const ValueKey('pos-cart-list')), matching: find.byType(Scrollable)).first);
        expect(list.height, greaterThanOrEqualTo(110));
        expect(panel.position.maxScrollExtent, lessThan(110));
        for (var uid = 1; uid <= items.length; uid++) {
          final line = find.byKey(ValueKey('pos-line-$uid'));
          await tester.ensureVisible(line);
          await tester.pump();
          final r = tester.getRect(line);
          expect(r.height, lessThanOrEqualTo(list.height), reason: 'line $uid');
          final shown = tester.getRect(find.byKey(const ValueKey('pos-cart-list')));
          expect(r.top >= shown.top - 0.5 && r.bottom <= shown.bottom + 0.5, isTrue, reason: 'line $uid within $shown: $r');
        }

        await tapVisible(tester, find.text(T.completeSale.s));
        expect(find.text(T.saleDone.s), findsOneWidget);
        final (sales, _) = await saved(tester, biz);
        final s = sales.single;
        expect((s.total, s.deliveryCharge, s.paid, s.contactId), (795.0, 60.0, 795.0, rahim));
        await closeApp(tester, biz);
      });
    }
  });
}
