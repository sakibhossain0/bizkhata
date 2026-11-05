import 'dart:io';

import 'package:bizkhata/app.dart';
import 'package:bizkhata/core/i18n.dart';
import 'package:bizkhata/core/util.dart';
import 'package:bizkhata/data/biz.dart';
import 'package:bizkhata/data/business_store.dart';
import 'package:bizkhata/data/seed.dart';
import 'package:bizkhata/state/app_state.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/sqlite3.dart' show sqlite3;

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
  });

  group('product with stock', () {
    test('a number typed as the unit is rejected (the reported bug)', () async {
      final b = Biz(AppDatabase(NativeDatabase.memory()));
      await seedBusiness(b, name: 'S', typeId: 'grocery', bangla: false);
      expect(
        () => b.products.create(const ProductInput(name: 'sunglass', unit: '1000', salePrice: 900)),
        throwsA(isA<BizException>().having((e) => e.message, 'code', 'unit_invalid')),
      );
      expect(isNumericUnit('১০০০'), isTrue);
      expect(isNumericUnit('kg'), isFalse);
      final id = await b.products.create(const ProductInput(name: 'sunglass', unit: 'pcs', salePrice: 900), openingStock: 100);
      expect((await b.products.byId(id))!.stock, 100);
    });

    testWidgets('adding a product from the form records its stock', (tester) async {
      currentLang = Lang.en;
      tester.view.physicalSize = const Size(1280, 680); // the reporter's laptop work area
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final biz = Biz(AppDatabase(NativeDatabase.memory()));
      await tester.runAsync(() => seedBusiness(biz, name: 'Shop', typeId: 'grocery', bangla: false));
      final session = Session(BusinessInfo(id: 't', name: 'Shop', type: 'grocery', createdAt: DateTime.now()), biz);
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

      appRouter.go('/products');
      await settle();
      await tester.tap(find.text(T.addProduct.s).first);
      await settle();

      // The stock box must be visible without scrolling on a 680px-tall screen.
      final stockBox = find.widgetWithText(TextField, '${T.stockNow.s} (pcs)');
      expect(stockBox, findsOneWidget);
      expect(tester.getRect(stockBox).bottom, lessThan(680));

      await tester.enterText(find.widgetWithText(TextField, T.productName.s), 'Sunglass');
      await tester.enterText(find.widgetWithText(TextField, T.salePrice.s), '900');
      await tester.enterText(find.widgetWithText(TextField, T.costPrice.s), '450');
      await tester.enterText(stockBox, '100');
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, T.save.s));
      await settle();

      late Product saved;
      late List<StockMove> moves;
      await tester.runAsync(() async {
        saved = (await biz.products.search('Sunglass')).single;
        moves = await biz.products.watchMoves(saved.id).first;
      });
      expect(saved.stock, 100);
      expect(saved.unit, 'pcs');
      expect(saved.salePrice, 900);
      expect(moves.single.kind, 'opening');
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 1));
      await tester.runAsync(() => biz.db.close());
    });
  });

  group('deleting a business is safe', () {
    late Directory tmp;
    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('bizkhata_store_');
      BusinessStore.overrideRoot = tmp.path;
      SharedPreferences.setMockInitialValues({});
    });
    tearDown(() async {
      BusinessStore.overrideRoot = null;
      try {
        await tmp.delete(recursive: true);
      } catch (_) {}
    });

    Future<String> makeBusinessFolder(String id, String name) async {
      final dbFile = await BusinessStore.dbPath(id);
      final db = sqlite3.open(dbFile);
      db.execute('CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT)');
      db.execute("INSERT INTO settings VALUES ('business_name', '$name')");
      db.close();
      File(p.join(p.dirname(dbFile), 'logo.png')).writeAsStringSync('x');
      return dbFile;
    }

    test('remove moves the folder to recently deleted, restore brings it back', () async {
      final info = await BusinessStore.add('Rahim Store', 'grocery');
      await makeBusinessFolder(info.id, 'Rahim Store');
      await BusinessStore.remove(info.id);

      expect(await BusinessStore.list(), isEmpty);
      expect(Directory(p.join(tmp.path, 'businesses', info.id)).existsSync(), isFalse);
      final deleted = await BusinessStore.deletedBusinesses();
      expect(deleted.single.name, 'Rahim Store');

      final back = await BusinessStore.restoreDeleted(info.id);
      expect(back.name, 'Rahim Store');
      expect((await BusinessStore.list()).single.id, info.id);
      expect(File(await BusinessStore.dbPath(info.id)).existsSync(), isTrue);
      expect(await BusinessStore.deletedBusinesses(), isEmpty);
    });

    test('orphaned folders (left by an old failed delete) are tidied at start-up', () async {
      await BusinessStore.add('Kept', 'grocery');
      await makeBusinessFolder('b123', 'Old Demo Shop');
      await BusinessStore.housekeeping();
      expect(Directory(p.join(tmp.path, 'businesses', 'b123')).existsSync(), isFalse);
      expect((await BusinessStore.deletedBusinesses()).single.name, 'Old Demo Shop');
      expect((await BusinessStore.list()).single.name, 'Kept');
    });

    test('a locked database file does not lose the delete', () async {
      final info = await BusinessStore.add('Locked', 'grocery');
      final dbFile = await makeBusinessFolder(info.id, 'Locked');
      // Hold the file open the way a not-yet-closed connection would.
      final raf = File(dbFile).openSync(mode: FileMode.append);
      await BusinessStore.remove(info.id);
      expect(await BusinessStore.list(), isEmpty, reason: 'still removed from the list');
      raf.closeSync();
      await BusinessStore.housekeeping(); // next start finishes the job
      expect((await BusinessStore.deletedBusinesses()).map((d) => d.id), contains(info.id));
    });
  });
}
