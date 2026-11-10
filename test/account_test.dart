import 'dart:io';

import 'package:bizkhata/app.dart';
import 'package:bizkhata/core/i18n.dart';
import 'package:bizkhata/data/business_store.dart';
import 'package:bizkhata/data/database.dart';
import 'package:drift/native.dart';
import 'package:bizkhata/state/app_state.dart';
import 'package:bizkhata/state/auth_state.dart';
import 'package:bizkhata/sync/google_auth.dart';
import 'package:bizkhata/sync/sync_engine.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Google without Google: [next] is the account the next sign-in picks.
class FakeGoogle implements GoogleAuth {
  String next = 'owner@example.com';
  int signIns = 0;
  int signOuts = 0;

  @override
  GoogleUser? user;

  @override
  bool get configured => true;

  @override
  Future<GoogleUser?> restore() async => user;

  @override
  Future<GoogleUser> signIn() async {
    signIns++;
    return user = GoogleUser(next, name: next.split('@').first);
  }

  @override
  Future<void> signOut() async {
    signOuts++;
    user = null;
  }

  @override
  Future<String> accessToken({bool refresh = false}) async => throw SyncException('not_signed_in');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late Directory dir;

  setUpAll(() async {
    await initializeDateFormatting('en');
    await initializeDateFormatting('bn');
  });

  setUp(() {
    dir = Directory.systemTemp.createTempSync('bk_account_');
    BusinessStore.overrideRoot = dir.path;
    // The real app opens shop databases through drift_flutter, which asks
    // path_provider for a temp folder; there are no plugins under flutter test.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'), (call) async => dir.path);
    // Same database files, opened on this isolate so the test clock drives them.
    BusinessStore.opener = (path) => AppDatabase(NativeDatabase(File(path)));
    SharedPreferences.setMockInitialValues({});
    AppController.requireAccount = true;
    currentLang = Lang.en;
  });

  tearDown(() {
    AppController.requireAccount = false;
    BusinessStore.overrideRoot = null;
    BusinessStore.opener = null;
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  group('shops belong to Google accounts', () {
    test('older shops go to the first account that signs in; each account sees its own', () async {
      final a = await BusinessStore.add('Old Shop', 'grocery');
      expect(a.owner, isNull);
      await BusinessStore.claimUnowned('Owner@Example.com');
      final b = await BusinessStore.add('Second Shop', 'pharmacy', owner: 'other@example.com');

      expect((await BusinessStore.listFor('owner@example.com')).map((x) => x.name), ['Old Shop'],
          reason: 'emails match without case');
      expect((await BusinessStore.listFor('other@example.com')).map((x) => x.id), [b.id]);
      expect(await BusinessStore.listFor('nobody@example.com'), isEmpty);
      expect(await BusinessStore.listFor(null), hasLength(2), reason: 'builds without accounts see everything');

      // Claiming again changes nothing that already has an owner.
      await BusinessStore.claimUnowned('third@example.com');
      expect(await BusinessStore.listFor('third@example.com'), isEmpty);
    });
  });

  testWidgets('sign in, create a shop, log out, and only the right account sees it', (tester) async {
    tester.view.physicalSize = const Size(1366, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final problems = <String>[];
    final previous = FlutterError.onError;
    FlutterError.onError = (details) {
      if (details.exception is MissingPluginException) return;
      // Closing a shop re-runs the providers that need it once before its
      // screens are gone (same when switching or deleting a shop); nothing shows.
      if ('${details.exception}'.contains('No open business')) return;
      final text = details.toString(minLevel: DiagnosticLevel.info);
      final where = RegExp(r'lib/[\w/]+\.dart:\d+:\d+').firstMatch(text)?.group(0) ?? '';
      final widget = RegExp(r'The relevant error-causing widget was:\s*\n\s*(.+)').firstMatch(text)?.group(1)?.trim() ?? '';
      problems.add('${details.exceptionAsString().split('\n').first}  $where  $widget');
    };
    final google = FakeGoogle();
    try {
      await tester.pumpWidget(ProviderScope(
        overrides: [googleAuthProvider.overrideWithValue(google)],
        child: const BizKhataApp(),
      ));

      Future<void> settle([int rounds = 6]) async {
        for (var i = 0; i < rounds; i++) {
          await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 120)));
          await tester.pump(const Duration(milliseconds: 200));
        }
      }

      Future<void> tapOn(Finder f) async {
        await tester.ensureVisible(f);
        await tester.pump();
        await tester.tap(f);
      }

      // Pump until [f] shows (database work and short timers in between).
      Future<void> until(Finder f, {int max = 200}) async {
        for (var i = 0; i < max && f.evaluate().isEmpty; i++) {
          await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
          await tester.pump(const Duration(milliseconds: 100));
        }
      }

      final continueButton = find.byKey(const ValueKey('continue-google'));
      final aboutBusiness = find.text(T.aboutYourBusiness.s);
      final shopName = find.text('Rahim Store');

      // Nobody signed in: the sign-in screen, and no sample-data shortcut anywhere.
      await until(continueButton);
      expect(continueButton, findsOneWidget);
      expect(find.textContaining('sample'), findsNothing);

      // First sign-in is the sign-up: straight to "about your business".
      await tapOn(continueButton);
      await until(aboutBusiness);
      expect(google.signIns, 1);
      expect(aboutBusiness, findsOneWidget);
      expect(find.textContaining('owner@example.com'), findsOneWidget);

      await tester.enterText(find.byType(TextField).first, 'Rahim Store');
      await tapOn(find.text(T.startFresh.s));
      await until(find.text(T.newSale.s));
      final shops = await tester.runAsync(() => BusinessStore.listFor('owner@example.com'));
      expect(shops!.single.name, 'Rahim Store');
      expect(shopName, findsWidgets, reason: 'the shop is open');

      // Log out from the shop menu at the top left (the menu and the dialog
      // ignore taps until their opening animation is over).
      await tester.tap(shopName.first);
      await settle(4);
      await tester.tap(find.text(T.logout.s).last);
      await until(find.widgetWithText(FilledButton, T.logout.s));
      await settle(3);
      await tester.tap(find.widgetWithText(FilledButton, T.logout.s));
      await until(continueButton);
      expect(google.signOuts, 1);
      expect(continueButton, findsOneWidget);

      // Someone else signs in on this PC: Rahim Store is not theirs.
      google.next = 'other@example.com';
      await tapOn(continueButton);
      await until(aboutBusiness);
      expect(aboutBusiness, findsOneWidget);
      expect(shopName, findsNothing);

      // Back to the owner: the shop opens straight away.
      await tapOn(find.text(T.logout.s));
      await until(find.widgetWithText(FilledButton, T.logout.s));
      await settle(3);
      await tester.tap(find.widgetWithText(FilledButton, T.logout.s));
      await until(continueButton);
      google.next = 'owner@example.com';
      await tapOn(continueButton);
      await until(find.text(T.newSale.s));
      expect(shopName, findsWidgets);
      expect(aboutBusiness, findsNothing);

      await tester.pumpWidget(const SizedBox());
      await settle(2);
    } finally {
      FlutterError.onError = previous;
    }
    expect(problems, isEmpty);
  });

  for (final lang in Lang.values) {
    for (final size in const [Size(1366, 768), Size(1280, 680), Size(820, 1180), Size(390, 844)]) {
      testWidgets('sign-in screen fits (${lang.name}, ${size.width.toInt()}x${size.height.toInt()})', (tester) async {
        currentLang = lang;
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final problems = <String>[];
        final previous = FlutterError.onError;
        FlutterError.onError = (details) {
          if (details.exception is MissingPluginException) return;
          problems.add(details.exceptionAsString().split('\n').first);
        };
        var found = 0;
        try {
          await tester.pumpWidget(ProviderScope(
            overrides: [googleAuthProvider.overrideWithValue(FakeGoogle())],
            child: const BizKhataApp(),
          ));
          for (var i = 0; i < 4; i++) {
            await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 80)));
            await tester.pump(const Duration(milliseconds: 200));
          }
          found = find.byKey(const ValueKey('continue-google')).evaluate().length;
          await tester.pumpWidget(const SizedBox());
        } finally {
          FlutterError.onError = previous;
        }
        expect(found, 1);
        expect(problems, isEmpty);
      });
    }
  }
}
