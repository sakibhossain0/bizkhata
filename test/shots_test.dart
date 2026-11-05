// Renders the main screens with demo data to PNGs for visual review.
// Not part of the normal suite — run explicitly:
//   flutter test test/shots_test.dart --run-skipped --update-goldens
// Images land in test/goldens/ (not committed); the README uses copies in docs/screenshots/.
@Tags(['shots'])
library;

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
import 'package:shared_preferences/shared_preferences.dart';

class _ReadyController extends AppController {
  final Session s;
  _ReadyController(this.s);
  @override
  AppPhase build() => Ready(s);
}

class _LockedController extends AppController {
  final Session s;
  _LockedController(this.s);
  @override
  AppPhase build() => Locked(s);
}

class _OnboardingController extends AppController {
  @override
  AppPhase build() => const Onboarding();
}

Future<void> _font(String family, List<String> files) async {
  final loader = FontLoader(family);
  for (final f in files) {
    loader.addFont(Future.value(ByteData.view(Uint8List.fromList(File(f).readAsBytesSync()).buffer)));
  }
  await loader.load();
}

/// The Flutter SDK folder: flutter_tester runs from `<flutter>/bin/cache/artifacts/engine/<platform>/`.
String _flutterRoot() {
  final env = Platform.environment['FLUTTER_ROOT'];
  if (env != null && env.isNotEmpty) return env;
  var dir = File(Platform.resolvedExecutable).parent;
  while (dir.parent.path != dir.path) {
    if (Directory('${dir.path}/bin/cache').existsSync()) return dir.path;
    dir = dir.parent;
  }
  throw StateError('Set FLUTTER_ROOT to the Flutter SDK folder');
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  setUpAll(() async {
    await initializeDateFormatting('en');
    await initializeDateFormatting('bn');
    await _font('HindSiliguri', [for (final w in ['Light', 'Regular', 'Medium', 'SemiBold', 'Bold']) 'assets/fonts/HindSiliguri-$w.ttf']);
    await _font('Bricolage', ['assets/fonts/BricolageGrotesque.ttf']);
    await _font('MaterialIcons', ['${_flutterRoot()}/bin/cache/artifacts/material_fonts/materialicons-regular.otf']);
  });

  testWidgets('onboarding', (tester) async {
    debugDisableShadows = false; // real shadows, not the test framework's solid outlines
    currentLang = Lang.bn;
    tester.view.physicalSize = const Size(1366, 768);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(
      overrides: [appProvider.overrideWith(() => _OnboardingController())],
      child: const BizKhataApp(),
    ));
    await tester.pump(const Duration(milliseconds: 400));
    await expectLater(find.byType(BizKhataApp), matchesGoldenFile('goldens/onboarding-bn.png'));
    debugDisableShadows = true;
  });

  const variants = [
    (Size(1366, 768), '', Lang.en),
    (Size(1366, 768), '', Lang.bn),
    (Size(390, 844), '-phone', Lang.bn),
    (Size(390, 844), '-phone', Lang.en),
  ];
  for (final (size, tag, lang) in variants) {
    final phone = tag.isNotEmpty;
    testWidgets('screens (${lang.name}$tag)', (tester) async {
      debugDisableShadows = false;
      currentLang = lang;
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final bn = lang == Lang.bn;
      final biz = Biz(AppDatabase(NativeDatabase.memory()));
      late int onlineId;
      late int customerId;
      await tester.runAsync(() async {
        await seedBusiness(biz, name: bn ? 'রহিম জেনারেল স্টোর' : 'Rahim General Store', typeId: 'grocery', bangla: bn);
        await seedDemoData(biz, bangla: bn);
        onlineId = (await biz.db.customSelect("SELECT MAX(id) AS id FROM sales WHERE channel = 'online'").getSingle()).read<int>('id');
        customerId = (await biz.contacts.watchContacts('customer', sort: ContactSort.balanceDesc).first).first.contact.id;
      });
      final session = Session(
          BusinessInfo(id: 't', name: bn ? 'রহিম জেনারেল স্টোর' : 'Rahim General Store', type: 'grocery', createdAt: DateTime.now()),
          biz);

      await tester.pumpWidget(ProviderScope(
        overrides: [appProvider.overrideWith(() => _ReadyController(session))],
        child: const BizKhataApp(),
      ));

      Future<void> settle() async {
        for (var i = 0; i < 3; i++) {
          await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 60)));
          await tester.pump(const Duration(milliseconds: 400));
        }
      }

      final shots = <String, String>{
        'dashboard': '/',
        'pos': '/pos',
        if (phone) 'pos-cart': '/pos',
        if (phone) 'customers': '/customers',
        'khata': '/customers/$customerId',
        'orders': '/orders',
        'order-detail': '/orders/$onlineId',
        'products': '/products/1',
        'cashbox': '/cashbox',
        'reports': '/reports',
        'settings': '/settings',
      };
      for (final e in shots.entries) {
        if (e.key != 'pos-cart') {
          appRouter.go(e.value);
          await settle();
        }
        if (e.key == 'pos-cart') {
          await tester.tap(find.ancestor(of: find.text(T.cart.s), matching: find.byType(InkWell)).first);
          await settle();
        }
        if (e.key == 'pos') {
          // Put a few things in the cart so the payment panel shows real numbers.
          for (final i in [0, 1, 5]) {
            await tester.tap(find.descendant(of: find.byType(GridView), matching: find.byType(GestureDetector)).at(i), warnIfMissed: false);
            await tester.pump(const Duration(milliseconds: 200));
          }
          // Some demo products are out of stock; don't let their messages into the pictures.
          tester.state<ScaffoldMessengerState>(find.byType(ScaffoldMessenger).first).clearSnackBars();
          await settle();
        }
        if (e.key == 'orders' && find.text(T.all.s).evaluate().isNotEmpty) {
          await tester.tap(find.text(T.all.s).first);
          await settle();
        }
        await expectLater(find.byType(BizKhataApp), matchesGoldenFile('goldens/${e.key}-${lang.name}$tag.png'));
      }

      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 1));
      await tester.runAsync(() => biz.db.close());
      debugDisableShadows = true;
    });
  }

  testWidgets('dialogs and staff (en)', (tester) async {
    debugDisableShadows = false;
    currentLang = Lang.en;
    tester.view.physicalSize = const Size(1366, 768);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});

    final biz = Biz(AppDatabase(NativeDatabase.memory()));
    await tester.runAsync(() async {
      await seedBusiness(biz, name: 'Rahim General Store', typeId: 'grocery', bangla: false);
      await seedDemoData(biz, bangla: false);
      await biz.settings.set(K.pinHash, hashPin('t', '1234'));
      await biz.staff.add(name: 'Karim', role: 'cashier', pin: '1111');
      await biz.staff.add(name: 'Nusrat', role: 'manager', pin: '2222');
    });
    final session = Session(BusinessInfo(id: 't', name: 'Rahim General Store', type: 'grocery', createdAt: DateTime.now()), biz);

    Future<void> settle() async {
      for (var i = 0; i < 3; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 60)));
        await tester.pump(const Duration(milliseconds: 400));
      }
    }

    Future<void> shot(String name) => expectLater(find.byType(BizKhataApp), matchesGoldenFile('goldens/$name-en.png'));

    await tester.pumpWidget(ProviderScope(
      overrides: [appProvider.overrideWith(() => _ReadyController(session))],
      child: const BizKhataApp(),
    ));

    appRouter.go('/');
    await settle();
    await tester.tap(find.text(T.dayEnd.s).first);
    await settle();
    await shot('day-end');
    await tester.tap(find.text(T.close.s).first);
    await settle();

    appRouter.go('/sales/1');
    await settle();
    await tester.tap(find.text(T.returnItems.s).first);
    await settle();
    await tester.tap(find.text(T.returnAll.s));
    await settle();
    await shot('return');
    await tester.tap(find.text(T.cancel.s).first);
    await settle();

    await tester.tap(find.byKey(const ValueKey('open-search')));
    await settle();
    await tester.enterText(find.byKey(const ValueKey('global-search')), 'ri');
    await settle();
    await settle();
    await shot('search');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle();

    appRouter.go('/settings');
    await settle();
    await tester.tap(find.textContaining(T.security.s).first);
    await settle();
    await shot('staff');

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));

    // The lock screen with staff to choose from.
    await tester.pumpWidget(ProviderScope(
      overrides: [appProvider.overrideWith(() => _LockedController(session))],
      child: const BizKhataApp(),
    ));
    await settle();
    await shot('lock');

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
    await tester.runAsync(() => biz.db.close());
    debugDisableShadows = true;
  });
}
