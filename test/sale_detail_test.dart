import 'dart:convert';
import 'dart:io';

import 'package:bizkhata/app.dart';
import 'package:bizkhata/core/format.dart';
import 'package:bizkhata/core/i18n.dart';
import 'package:bizkhata/data/biz.dart';
import 'package:bizkhata/data/business_store.dart';
import 'package:bizkhata/data/seed.dart';
import 'package:bizkhata/services/templates.dart';
import 'package:bizkhata/state/app_state.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

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

/// A counter sale with every total row: 2 × ৳100 bought at ৳63, ৳20 off,
/// 5% VAT and the delivery charge, ৳200 paid in cash and the rest due.
/// Without delivery: 200 - 20 + 9 VAT = 189.
Future<int> _sale(Biz b, {double delivery = 60}) async {
  final cust = await b.contacts.customerFor(name: 'Rahim', phone: '01711000001');
  return b.sales.createSale(
    lines: const [CartLine(name: 'Miniket Rice', qty: 2, price: 100, cost: 63)],
    discount: 20,
    vatPercent: 5,
    deliveryCharge: delivery,
    contactId: cust,
    paid: 200,
    accountId: await b.cash.defaultCashAccount(),
  );
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  group('invoice message', () {
    test('the delivery charge is listed after the items, so they add up to the total', () async {
      currentLang = Lang.en;
      final b = Biz(AppDatabase(NativeDatabase.memory()));
      await seedBusiness(b, name: 'Shop', typeId: 'grocery', bangla: false);
      final d = (await b.sales.detail(await _sale(b)))!;
      final lines = invoiceMessage(const {}, d).split('\n');
      final item = lines.indexOf('• Miniket Rice × 2 = ${money(200)}');
      expect(item, greaterThan(0), reason: lines.join('\n'));
      expect(lines[item + 1], '• ${T.deliveryCharge.s} = ${money(60)}');
      expect(lines[item + 2], 'Total ${money(249)} · Paid ${money(200)} · Due ${money(49)}');
      expect(lines.where((l) => l.contains(T.deliveryCharge.s)), hasLength(1));

      // The shop's own message without an item list: the charge goes at the end.
      final own = {K.templates: jsonEncode({'invoice': 'Thanks {name}! Total {total}'})};
      expect(invoiceMessage(own, d), 'Thanks Rahim! Total ${money(249)}\n${T.deliveryCharge.s}: ${money(60)}');

      // No delivery, no line.
      final plain = (await b.sales.detail(await _sale(b, delivery: 0)))!;
      expect(invoiceMessage(const {}, plain), isNot(contains(T.deliveryCharge.s)));
      await b.db.close();
    });
  });

  group('Sale details', () {
    setUpAll(() async {
      await initializeDateFormatting('en');
      await initializeDateFormatting('bn');
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

    /// A totals row: the label on the left, the amount on the right.
    Finder row(String label, String value) => find.byWidgetPredicate((w) =>
        w is Row &&
        w.children.length == 3 &&
        w.children.first is Text &&
        (w.children.first as Text).data == label &&
        w.children.last is Text &&
        (w.children.last as Text).data == value);

    for (final lang in Lang.values) {
      testWidgets('a counter sale with delivery (${lang.name}): the totals and the profit add up, and the shared text has it',
          (tester) async {
        currentLang = lang;
        tester.view.physicalSize = const Size(1366, 768);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        String? copied;
        final messenger = tester.binding.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String?;
          return null;
        });
        addTearDown(() => messenger.setMockMethodCallHandler(SystemChannels.platform, null));

        final biz = Biz(AppDatabase(NativeDatabase.memory()));
        late int id;
        await tester.runAsync(() async {
          await seedBusiness(biz, name: 'Shop', typeId: 'grocery', bangla: lang == Lang.bn);
          id = await _sale(biz);
        });
        final session = Session(BusinessInfo(id: 't', name: 'Shop', type: 'grocery', createdAt: DateTime.now()), biz);
        await tester.pumpWidget(ProviderScope(
          overrides: [appProvider.overrideWith(() => _ReadyController(session))],
          child: const BizKhataApp(),
        ));
        appRouter.go('/sales/$id');
        await settle(tester);

        // 200 - 20 + 9 VAT + 60 delivery = 249.
        expect(row(T.subtotal.s, money(200)), findsOneWidget);
        expect(row(T.discount.s, '−${money(20)}'), findsOneWidget);
        expect(row(T.vat.s, money(9)), findsOneWidget);
        expect(row(T.deliveryCharge.s, money(60)), findsOneWidget);
        expect(row(T.total.s, money(249)), findsOneWidget);
        expect(row(T.due.s, money(49)), findsOneWidget);
        // 180 net sales + 60 delivery - 126 cost = 114 gross profit.
        expect(row(T.netSales.s, money(180)), findsOneWidget);
        expect(row(T.deliveryIncome.s, money(60)), findsOneWidget);
        expect(row(T.cogs.s, '−${money(126)}'), findsOneWidget);
        expect(row(T.grossProfit.s, money(114)), findsOneWidget);

        await tester.tap(find.byTooltip(T.share.s));
        await settle(tester);
        await tester.tap(find.text(T.copyText.s));
        await settle(tester);
        expect(find.text(T.copied.s), findsOneWidget);
        final lines = copied!.split('\n');
        final item = lines.indexWhere((l) => l.startsWith('• Miniket Rice'));
        expect(item, greaterThan(0), reason: copied);
        expect(lines[item + 1], '• ${T.deliveryCharge.s} = ${money(60)}');

        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 1));
        await tester.runAsync(() => biz.db.close());
      });
    }
  });
}
