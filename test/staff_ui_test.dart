import 'dart:io';

import 'package:bizkhata/app.dart';
import 'package:bizkhata/core/i18n.dart';
import 'package:bizkhata/data/biz.dart';
import 'package:bizkhata/data/business_store.dart';
import 'package:bizkhata/data/seed.dart';
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

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  setUpAll(() async {
    await initializeDateFormatting('en');
    await initializeDateFormatting('bn');
    // Real fonts, so text measures like in the app.
    Future<void> load(String family, List<String> files) async {
      final loader = FontLoader(family);
      for (final f in files) {
        loader.addFont(Future.value(ByteData.view(Uint8List.fromList(File(f).readAsBytesSync()).buffer)));
      }
      await loader.load();
    }

    await load('HindSiliguri', [for (final w in ['Light', 'Regular', 'Medium', 'SemiBold', 'Bold']) 'assets/fonts/HindSiliguri-$w.ttf']);
    await load('Bricolage', ['assets/fonts/BricolageGrotesque.ttf']);
  });

  testWidgets('a cashier sees only selling pages, never costs or settings', (tester) async {
    currentLang = Lang.en;
    tester.view.physicalSize = const Size(1280, 680);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final biz = Biz(AppDatabase(NativeDatabase.memory()));
    late StaffUser cashier;
    await tester.runAsync(() async {
      await seedBusiness(biz, name: 'Shop', typeId: 'grocery', bangla: false);
      await seedDemoData(biz, bangla: false);
      final id = await biz.staff.add(name: 'Karim', role: 'cashier', pin: '1234');
      cashier = (await biz.staff.byId(id))!;
    });
    final actor = Actor.staff(cashier);
    biz.db.actor = actor.stamp;
    final session = Session(BusinessInfo(id: 't', name: 'Shop', type: 'grocery', createdAt: DateTime.now()), biz, actor);
    await tester.pumpWidget(ProviderScope(
      overrides: [appProvider.overrideWith(() => _ReadyController(session))],
      child: const BizKhataApp(),
    ));
    Future<void> settle() async {
      for (var i = 0; i < 3; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
        await tester.pump(const Duration(milliseconds: 300));
      }
    }

    // The dashboard is not theirs: they land on the counter.
    appRouter.go('/');
    await settle();
    await settle();
    expect(appRouter.routerDelegate.currentConfiguration.uri.path, '/pos');

    // Sidebar: no reports, expenses, cashbox, purchases, suppliers or settings.
    for (final t in [T.reports, T.expenses, T.cashbox, T.purchases, T.suppliers, T.settings, T.dashboard]) {
      expect(find.text(t.s), findsNothing, reason: '${t.name} should be hidden');
    }
    expect(find.text('Karim · ${T.role_cashier.s}'), findsOneWidget);

    // Typing a forbidden page sends them back.
    appRouter.go('/reports');
    await settle();
    await settle();
    expect(appRouter.routerDelegate.currentConfiguration.uri.path, '/pos');

    // Products: no cost column, no add button.
    appRouter.go('/products');
    await settle();
    expect(find.text(T.costPrice.s), findsNothing);
    expect(find.text(T.addProduct.s), findsNothing);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
    await tester.runAsync(() => biz.db.close());
  });
}
