import 'dart:convert';
import 'dart:io';

import 'package:bizkhata/core/i18n.dart';
import 'package:bizkhata/core/theme.dart';
import 'package:bizkhata/data/biz.dart';
import 'package:bizkhata/data/business_store.dart';
import 'package:bizkhata/data/seed.dart';
import 'package:bizkhata/state/app_state.dart';
import 'package:bizkhata/state/cloud_state.dart';
import 'package:bizkhata/sync/cloud_sync.dart';
import 'package:bizkhata/sync/google_auth.dart';
import 'package:bizkhata/sync/remote_store.dart';
import 'package:bizkhata/sync/sync_engine.dart';
import 'package:bizkhata/ui/screens/onboarding_screen.dart';
import 'package:bizkhata/ui/widgets/cloud_widgets.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

/// A signed-in Google account; [driveAllowed] is what the consent page said.
class _Google implements GoogleAuth {
  @override
  void cancelPendingConsent() {}

  _Google(this.user);

  @override
  GoogleUser? user;

  @override
  bool driveAllowed = true;

  @override
  bool get configured => true;

  @override
  Future<GoogleUser?> restore() async => user;

  @override
  Future<GoogleUser> signIn() async => user = GoogleUser('owner@example.com');

  @override
  Future<void> signOut() async => user = null;

  @override
  Future<void> allowDrive() async => driveAllowed = true;

  @override
  Future<String> accessToken({bool refresh = false}) async => 'token';
}

/// The memory "Drive", counting what reaches it. It can be offline, or fail
/// the next write of one kind ('snap', 'meta' ...); with [saveFirst] that
/// write lands and only the answer is lost. Given an [account], it refuses
/// like Google Drive while that account hasn't allowed it.
class _Drive extends MemoryRemoteStore {
  int calls = 0;
  bool offline = false;
  String? failNext;
  bool saveFirst = false;
  _Google? account;

  @override
  Future<List<RemoteFile>> list(Map<String, String> props, {DateTime? modifiedAfter}) async {
    calls++;
    if (offline) throw SyncException('network', 'offline');
    if (account?.driveAllowed == false) throw SyncException('no_drive');
    return super.list(props, modifiedAfter: modifiedAfter);
  }

  @override
  Future<RemoteFile> write(String name, List<int> bytes, {Map<String, String> props = const {}, RemoteFile? replace}) async {
    calls++;
    if (offline) throw SyncException('network', 'offline');
    if (account?.driveAllowed == false) throw SyncException('no_drive');
    if (failNext != null && props['kind'] == failNext) {
      failNext = null;
      if (saveFirst) await super.write(name, bytes, props: props, replace: replace);
      throw SyncException('network', 'connection reset');
    }
    return super.write(name, bytes, props: props, replace: replace);
  }
}

class _Open extends AppController {
  final Session s;
  _Open(this.s);
  @override
  AppPhase build() => Ready(s);
}

/// Opened with an owner PIN set: locked, with the owner as a stand-in, until
/// someone enters a PIN.
class _Locked extends AppController {
  final Session s;
  _Locked(this.s);
  @override
  AppPhase build() => Locked(s);

  @override
  Future<void> lock() async {
    state = Locked(s);
  }

  void unlockAs(Actor actor) => state = Ready(Session(s.info, s.biz, actor));
}

class _FirstRun extends AppController {
  @override
  AppPhase build() => const Onboarding();
}

/// A shop that isn't in Drive, without a database behind it.
class _NotSyncing extends CloudSyncController {
  @override
  CloudStatus build() => const CloudStatus();
}

Matcher _fails(String code) => throwsA(isA<SyncException>().having((e) => e.code, 'code', code));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  group('which shops go to Google Drive by themselves', () {
    final owner = GoogleUser('owner@example.com');
    bool may({bool byOwner = true, String? shop = 'owner@example.com', GoogleUser? user, bool drive = true, DateTime? failedAt, DateTime? now}) =>
        mayAutoUpload(byOwner: byOwner, shopOwner: shop, user: user, driveAllowed: drive, failedAt: failedAt, now: now);

    test("the owner's, signed in with Drive allowed", () {
      expect(may(user: owner), isTrue);
      expect(may(user: GoogleUser('Owner@Example.com')), isTrue, reason: 'emails match without case');
      expect(may(user: owner, shop: null), isTrue, reason: 'a shop made before accounts');
    });

    test("not without an account or Drive, not by staff, not another account's shop", () {
      expect(may(user: null), isFalse);
      expect(may(user: owner, drive: false), isFalse);
      expect(may(user: owner, byOwner: false), isFalse);
      expect(may(user: owner, shop: 'other@example.com'), isFalse);
    });

    test('after a failed try, the next waits five minutes', () {
      final now = DateTime(2026, 11, 13, 10);
      expect(may(user: owner, failedAt: now.subtract(const Duration(minutes: 4)), now: now), isFalse);
      expect(may(user: owner, failedAt: now.subtract(const Duration(minutes: 5)), now: now), isTrue);
    });
  });

  group('automatic upload', () {
    late Directory dir;
    late _Drive drive;
    late Biz biz;
    late _Google google;
    ProviderContainer? container;

    setUp(() async {
      dir = Directory.systemTemp.createTempSync('bk_drive_');
      BusinessStore.overrideRoot = dir.path;
      drive = _Drive();
      biz = Biz(AppDatabase(NativeDatabase.memory()));
      await seedBusiness(biz, name: 'Rahim Store', typeId: 'grocery', bangla: false);
      google = _Google(GoogleUser('owner@example.com'));
    });

    tearDown(() async {
      container?.dispose();
      container = null;
      await biz.db.close();
      BusinessStore.overrideRoot = null;
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    });

    Future<void> until(bool Function() ok, {Duration limit = const Duration(seconds: 3)}) async {
      final end = DateTime.now().add(limit);
      while (!ok() && DateTime.now().isBefore(end)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    }

    // Time for the controller to do something, when the point is that it doesn't.
    Future<void> pause() => Future<void>.delayed(const Duration(milliseconds: 400));

    /// Opens the shop the way the app does: the account is restored first.
    /// With [locked], an owner PIN is set and nobody has entered it yet.
    Future<ProviderContainer> open({String? owner = 'owner@example.com', Actor actor = Actor.owner, bool locked = false}) async {
      container?.dispose();
      final info = BusinessInfo(id: 'b1', name: 'Rahim Store', type: 'grocery', createdAt: DateTime(2026), owner: owner);
      final session = Session(info, biz, actor);
      final c = container = ProviderContainer(overrides: [
        appProvider.overrideWith(() => locked ? _Locked(session) : _Open(session)),
        googleAuthProvider.overrideWithValue(google),
        cloudProvider.overrideWithValue(CloudSync(drive)),
      ]);
      await c.read(googleUserProvider.notifier).restore();
      c.listen(cloudSyncProvider, (_, _) {});
      return c;
    }

    Future<void> signInAgain(ProviderContainer c) async {
      await c.read(googleUserProvider.notifier).signOut();
      await c.read(googleUserProvider.notifier).signIn();
    }

    test("a shop goes to Drive by itself once its owner's account allows it", () async {
      final c = await open();
      await until(() => c.read(cloudSyncProvider).on);
      expect(c.read(cloudSyncProvider).on, isTrue);
      expect(c.read(cloudSyncProvider).error, isNull);
      expect((await CloudSync(drive).businesses()).map((b) => b.name), ['Rahim Store']);
      final engine = SyncEngine(biz.db);
      expect(await engine.isOn, isTrue);
      expect(await engine.get('first_upload'), isNull);
    });

    test('without Drive nothing goes up; allowing it uploads at once', () async {
      google.driveAllowed = false;
      final c = await open();
      await pause();
      expect(drive.calls, 0);
      expect(c.read(driveAccessProvider), isFalse);
      await c.read(driveAccessProvider.notifier).allow();
      expect(c.read(driveAccessProvider), isTrue);
      await until(() => c.read(cloudSyncProvider).on);
      expect(await CloudSync(drive).businesses(), hasLength(1));
    });

    test('"Put this shop in Google Drive" refused for want of Drive: allowing it uploads at once, error gone', () async {
      google.driveAllowed = false;
      drive.account = google;
      final c = await open();
      await pause();
      await expectLater(c.read(cloudSyncProvider.notifier).enable(), _fails('no_drive'));
      expect(c.read(cloudSyncProvider).error, 'no_drive');
      await c.read(driveAccessProvider.notifier).allow();
      await until(() => c.read(cloudSyncProvider).on, limit: const Duration(seconds: 1));
      expect(c.read(cloudSyncProvider).on, isTrue, reason: 'no five-minute wait after a refusal that sent nothing');
      expect(c.read(cloudSyncProvider).error, isNull);
      expect(await CloudSync(drive).businesses(), hasLength(1));
    });

    test('nothing goes up while the app is locked at start-up; the owner unlocking starts it', () async {
      final c = await open(locked: true);
      await pause();
      expect(drive.calls, 0, reason: 'nobody has entered a PIN yet');
      final app = c.read(appProvider.notifier) as _Locked;
      app.unlockAs(Actor.staff(StaffUser(id: 1, name: 'Karim', pinHash: 'x', role: 'cashier', active: true, createdAt: DateTime(2026))));
      await pause();
      expect(drive.calls, 0, reason: 'staff never put the shop in Drive');
      await app.lock();
      app.unlockAs(Actor.owner);
      await until(() => c.read(cloudSyncProvider).on, limit: const Duration(seconds: 1));
      expect(c.read(cloudSyncProvider).on, isTrue);
      expect(await CloudSync(drive).businesses(), hasLength(1));
    });

    test("another account's shop, or staff using the app, stays on this device", () async {
      await open(owner: 'other@example.com');
      await pause();
      expect(drive.calls, 0);
      final cashier = Actor.staff(StaffUser(id: 1, name: 'Karim', pinHash: 'x', role: 'cashier', active: true, createdAt: DateTime(2026)));
      await open(actor: cashier);
      await pause();
      expect(drive.calls, 0);
    });

    test('a shop already in Drive, even paused there, is left alone', () async {
      final engine = SyncEngine(biz.db);
      await engine.set('on', '1');
      await engine.setPaused(true);
      final c = await open();
      await pause();
      expect(drive.calls, 0);
      expect(c.read(cloudSyncProvider).paused, isTrue);
    });

    test('a copy made elsewhere is not uploaded over, and no more tries follow', () async {
      await drive.write(
        'bk_b1_meta.json',
        utf8.encode(jsonEncode({'id': 'b1', 'name': 'Rahim Store', 'type': 'grocery', 'snapshot': {}, 'devices': {}})),
        props: {'biz': 'b1', 'kind': 'meta'},
      );
      final c = await open();
      await until(() => c.read(cloudSyncProvider).error != null);
      expect(c.read(cloudSyncProvider).error, 'already_in_cloud');
      expect(c.read(cloudSyncProvider).on, isFalse);
      expect(await SyncEngine(biz.db).isOn, isFalse);
      final calls = drive.calls;
      // Signing in again would otherwise try at once.
      await signInAgain(c);
      await pause();
      expect(drive.calls, calls);
      expect(await drive.list({'kind': 'meta'}), hasLength(1));
    });

    test('offline: the next automatic try waits; asked for by hand, it goes at once', () async {
      drive.offline = true;
      final c = await open();
      await until(() => c.read(cloudSyncProvider).error != null);
      expect(c.read(cloudSyncProvider).error, 'network');
      drive.offline = false;
      final calls = drive.calls;
      await signInAgain(c);
      await pause();
      expect(drive.calls, calls, reason: 'too soon after the failure');
      await c.read(cloudSyncProvider.notifier).enable();
      expect(c.read(cloudSyncProvider).on, isTrue);
      expect(c.read(cloudSyncProvider).error, isNull);
      expect(await CloudSync(drive).businesses(), hasLength(1));
    });

    test('an upload that broke off half-way is finished next time, not left syncing into nowhere', () async {
      // The full copy goes up, the shop's entry in Drive doesn't.
      drive.failNext = 'meta';
      var c = await open();
      await until(() => c.read(cloudSyncProvider).error != null);
      final engine = SyncEngine(biz.db);
      expect(await engine.isOn, isTrue, reason: 'CloudSync.upload turns syncing on before the copy is up');
      expect(c.read(cloudSyncProvider).on, isFalse);
      expect(await CloudSync(drive).businesses(), isEmpty);

      c = await open();
      expect(c.read(cloudSyncProvider).on, isFalse);
      await until(() => c.read(cloudSyncProvider).on);
      expect(c.read(cloudSyncProvider).error, isNull);
      expect(await CloudSync(drive).businesses(), hasLength(1));
      expect(await engine.get('first_upload'), isNull);
    });

    test('an upload cut off during the photos sends the rest next time', () async {
      final images = await BusinessStore.imagesDir('b1');
      for (final name in ['p1.jpg', 'p2.jpg', 'p3.jpg']) {
        File(p.join(images.path, name)).writeAsBytesSync([1, 2, 3]);
      }
      // The full copy and the shop's entry go up; the photos (sent last) don't.
      drive.failNext = 'img';
      var c = await open();
      await until(() => c.read(cloudSyncProvider).error != null);
      expect(await CloudSync(drive).businesses(), hasLength(1));
      expect(await drive.list({'kind': 'img'}), isEmpty);

      c = await open();
      await until(() => c.read(cloudSyncProvider).on);
      expect(c.read(cloudSyncProvider).error, isNull);
      expect((await drive.list({'kind': 'img'})).map((f) => f.props['file']).toSet(), {'p1.jpg', 'p2.jpg', 'p3.jpg'});
      expect(await SyncEngine(biz.db).get('first_upload'), isNull);
    });

    test('when only the answer was lost, the copy in Drive is kept, not made twice', () async {
      drive
        ..failNext = 'meta'
        ..saveFirst = true;
      var c = await open();
      await until(() => c.read(cloudSyncProvider).error != null);
      c = await open();
      await until(() => c.read(cloudSyncProvider).on);
      expect(c.read(cloudSyncProvider).error, isNull);
      expect(await drive.list({'kind': 'meta'}), hasLength(1));
      expect(await SyncEngine(biz.db).get('first_upload'), isNull);
    });
  });

  group('on screen', () {
    setUpAll(() async {
      await initializeDateFormatting('en');
      await initializeDateFormatting('bn');
    });

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      currentLang = Lang.en;
    });

    // Toasts end on a timer; let them before the test ends.
    Future<void> letToastsGo(WidgetTester tester) async {
      await tester.pump(const Duration(seconds: 6));
      await tester.pumpAndSettle();
    }

    testWidgets('the banner asks for Drive and goes once it is allowed', (tester) async {
      final google = _Google(GoogleUser('owner@example.com'))..driveAllowed = false;
      final c = ProviderContainer(overrides: [googleAuthProvider.overrideWithValue(google)]);
      addTearDown(c.dispose);
      await c.read(googleUserProvider.notifier).restore();
      await tester.pumpWidget(UncontrolledProviderScope(
        container: c,
        child: MaterialApp(theme: buildTheme(), home: const Scaffold(body: DriveAccessBanner())),
      ));
      expect(find.text(T.drNotAllowed.s), findsOneWidget);
      await tester.tap(find.text(T.drAllow.s));
      await tester.pumpAndSettle();
      expect(find.text(T.drNotAllowed.s), findsNothing);
      expect(find.text(T.drAllowed.s), findsOneWidget);
      await letToastsGo(tester);
    });

    testWidgets('the sidebar\'s "Drive not allowed" chip asks Google again in one tap', (tester) async {
      final google = _Google(GoogleUser('owner@example.com'))..driveAllowed = false;
      final c = ProviderContainer(overrides: [
        googleAuthProvider.overrideWithValue(google),
        actorProvider.overrideWithValue(Actor.owner),
        cloudSyncProvider.overrideWith(_NotSyncing.new),
      ]);
      addTearDown(c.dispose);
      await c.read(googleUserProvider.notifier).restore();
      await tester.pumpWidget(UncontrolledProviderScope(
        container: c,
        child: MaterialApp(theme: buildTheme(), home: const Scaffold(body: CloudStatusChip())),
      ));
      await tester.tap(find.text(T.drChipNotAllowed.s));
      await tester.pumpAndSettle();
      expect(google.driveAllowed, isTrue, reason: 'asked right away, not sent to a Settings page');
      expect(find.text(T.drChipNotAllowed.s), findsNothing);
      expect(find.text(T.drAllowed.s), findsOneWidget);
      await letToastsGo(tester);
    });

    testWidgets("first run on a new device: the account's shops in Drive come first", (tester) async {
      tester.view.physicalSize = const Size(1366, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      AppController.requireAccount = true;
      addTearDown(() => AppController.requireAccount = false);
      final store = MemoryRemoteStore();
      await store.write(
        'bk_b9_meta.json',
        utf8.encode(jsonEncode({'id': 'b9', 'name': 'Karim Traders', 'type': 'grocery', 'snapshot': {}, 'devices': {}})),
        props: {'biz': 'b9', 'kind': 'meta'},
      );
      final google = _Google(GoogleUser('owner@example.com'))..driveAllowed = false;
      final c = ProviderContainer(overrides: [
        appProvider.overrideWith(_FirstRun.new),
        googleAuthProvider.overrideWithValue(google),
        cloudProvider.overrideWithValue(CloudSync(store)),
      ]);
      addTearDown(c.dispose);
      await c.read(googleUserProvider.notifier).restore();
      await tester.pumpWidget(UncontrolledProviderScope(container: c, child: MaterialApp(theme: buildTheme(), home: const OnboardingScreen())));
      await tester.pumpAndSettle();

      // Drive not allowed yet: the banner instead of the list.
      expect(find.text(T.drNotAllowed.s), findsOneWidget);
      expect(find.text(T.drShopsTitle.s), findsNothing);
      await tester.tap(find.text(T.drAllow.s));
      await tester.pumpAndSettle();
      expect(find.text(T.drNotAllowed.s), findsNothing);
      expect(find.text(T.drShopsTitle.s), findsOneWidget);
      expect(find.text('Karim Traders'), findsOneWidget);
      expect(find.text(T.startFresh.s), findsOneWidget, reason: 'a new shop can still be made');
      await letToastsGo(tester);
    });
  });
}
