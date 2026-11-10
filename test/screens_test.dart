import 'dart:io';

import 'package:bizkhata/app.dart';
import 'package:bizkhata/core/i18n.dart';
import 'package:bizkhata/data/biz.dart';
import 'package:bizkhata/data/business_store.dart';
import 'package:bizkhata/data/seed.dart';
import 'package:bizkhata/state/app_state.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

Future<void> _tap(WidgetTester tester, Finder f, List<String> problems, String where) async {
  if (f.evaluate().isEmpty) {
    problems.add('[$where] could not find tab/section to tap');
    return;
  }
  await tester.tap(f.first, warnIfMissed: false);
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  setUpAll(() async {
    await initializeDateFormatting('en');
    await initializeDateFormatting('bn');
    // Real fonts, so text measures like in the app (the default test font is much wider).
    await _loadFont('HindSiliguri', [
      for (final w in ['Light', 'Regular', 'Medium', 'SemiBold', 'Bold']) 'assets/fonts/HindSiliguri-$w.ttf',
    ]);
    await _loadFont('Bricolage', ['assets/fonts/BricolageGrotesque.ttf']);
  });

  // 1280x680 is a 1080p laptop at 150% scaling with the taskbar, the owner's own screen.
  const sizes = [Size(1366, 768), Size(1280, 680), Size(1024, 660), Size(820, 1180), Size(390, 844)];

  for (final lang in Lang.values) {
    for (final size in sizes) {
      testWidgets('every screen renders cleanly (${lang.name}, ${size.width.toInt()}x${size.height.toInt()})', (tester) async {
        currentLang = lang;
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);

        final problems = <String>[];
        final previous = FlutterError.onError;
        var where = 'boot';
        FlutterError.onError = (details) {
          // No platform plugins under `flutter test` (path_provider etc.).
          if (details.exception is MissingPluginException) return;
          final text = details.toString(minLevel: DiagnosticLevel.info);
          final loc = RegExp(r'lib/[\w/]+\.dart:\d+:\d+').firstMatch(text)?.group(0) ?? '';
          problems.add('[$where] ${details.exceptionAsString().split('\n').first}  $loc');
        };

        SharedPreferences.setMockInitialValues({});
        final biz = Biz(AppDatabase(NativeDatabase.memory()));
        try {
        late int onlineId;
        await tester.runAsync(() async {
          await seedBusiness(biz, name: 'Rahim General Store', typeId: 'grocery', bangla: lang == Lang.bn);
          await seedDemoData(biz, bangla: lang == Lang.bn);
          onlineId = (await biz.db.customSelect("SELECT MAX(id) AS id FROM sales WHERE channel = 'online'").getSingle()).read<int>('id');
        });
        final session = Session(BusinessInfo(id: 't', name: 'Rahim General Store', type: 'grocery', createdAt: DateTime.now()), biz);

        await tester.pumpWidget(ProviderScope(
          overrides: [appProvider.overrideWith(() => _ReadyController(session))],
          child: const BizKhataApp(),
        ));

        Future<void> settle() async {
          for (var i = 0; i < 2; i++) {
            await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
            await tester.pump(const Duration(milliseconds: 300));
          }
        }

        for (final path in [
          '/', '/pos', '/sales', '/sales/1', '/orders', '/orders/new', '/orders/$onlineId', '/products', '/products/1',
          '/purchases', '/purchases/new', '/customers', '/customers/1', '/suppliers', '/suppliers/5', '/expenses',
          '/cashbox', '/reports', '/settings',
        ]) {
          where = path;
          appRouter.go(path);
          await settle();
          if (path == '/') {
            where = 'day-end dialog';
            await _tap(tester, find.text(T.dayEnd.s), problems, where);
            await settle();
            await _tap(tester, find.text(T.close.s), problems, where);
            await settle();
          }
          if (path == '/sales/1') {
            where = 'return dialog';
            await _tap(tester, find.text(T.returnItems.s), problems, where);
            await settle();
            await _tap(tester, find.text(T.returnAll.s), problems, where);
            await settle();
            await _tap(tester, find.text(T.cancel.s), problems, where);
            await settle();
          }
          if (path == '/products') {
            where = 'global search';
            await _tap(tester, find.byKey(const ValueKey('open-search')), problems, where);
            await settle();
            final box = find.byKey(const ValueKey('global-search'));
            if (box.evaluate().isNotEmpty) {
              await tester.enterText(box, 'a');
              await settle();
              await tester.sendKeyEvent(LogicalKeyboardKey.escape);
              await settle();
            } else {
              problems.add('[$where] search box did not open');
            }
          }
          // Phone POS: add a product, open the full-screen cart, come back.
          if (path == '/pos' && size.width < 900) {
            final cards = find.descendant(of: find.byType(GridView), matching: find.byType(GestureDetector));
            if (cards.evaluate().isNotEmpty) {
              await tester.tap(cards.first, warnIfMissed: false);
              await settle();
              where = '/pos cart page';
              await _tap(tester, find.text(T.cart.s), problems, where);
              await settle();
              await _tap(tester, find.byIcon(Icons.arrow_back_rounded), problems, where);
              await settle();
            }
          }
        }

        where = '/reports tabs';
        appRouter.go('/reports');
        await settle();
        for (final tab in [T.profitLoss, T.topSelling, T.stockReport, T.dueReport, T.expenseReport, T.cashbook, T.byStaff]) {
          where = 'report:${tab.name}';
          await _tap(tester, find.descendant(of: find.byType(TabBar), matching: find.text(tab.s)), problems, where);
          await settle();
        }
        appRouter.go('/settings');
        await settle();
        for (final section in [T.invoiceSettings, T.onlineSettings, T.webTitle, T.smsGateway, T.cloudTitle, T.security, T.backup, T.about]) {
          where = 'settings:${section.name}';
          await _tap(tester, find.textContaining(section.s), problems, where);
          await settle();
          // Narrow screens open one section at a time; go back to the list.
          if (size.width < 900) {
            await _tap(tester, find.byIcon(Icons.arrow_back_rounded), problems, where);
            await settle();
          }
        }

        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 1));
        await tester.runAsync(() => biz.db.close());
        } catch (e, st) {
          final trace = st.toString().split('\n').take(6).join('\n');
          problems.add('[$where] threw: $e\n$trace');
        } finally {
          FlutterError.onError = previous;
        }
        expect(problems.toSet().toList(), isEmpty);
      });
    }
  }
}
