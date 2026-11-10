import 'dart:io';

import 'package:bizkhata/data/biz.dart';
import 'package:bizkhata/data/business_store.dart';
import 'package:bizkhata/data/seed.dart';
import 'package:bizkhata/sync/cloud_sync.dart';
import 'package:bizkhata/sync/remote_store.dart';
import 'package:bizkhata/sync/sync_engine.dart';
import 'package:bizkhata/sync/sync_schema.dart';
import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// One "device": its own database file, engine and the shared cloud.
class Device {
  final Biz biz;
  final SyncEngine engine;
  final String name;
  Device(this.biz, this.name) : engine = SyncEngine(biz.db);
  AppDatabase get db => biz.db;
}

Future<int> cashId(Biz b) async => (await b.cash.accounts()).first.id;

/// Every synced row, by table, ordered by key — what two devices must agree on.
Future<Map<String, List<Map<String, Object?>>>> dump(AppDatabase db) async {
  final out = <String, List<Map<String, Object?>>>{};
  for (final t in syncTables) {
    final col = syncKeyColumn(t);
    final rows = await db.customSelect('SELECT * FROM "$t" ORDER BY "$col"').get();
    out[t] = [
      for (final r in rows)
        if (t != 'settings' || !localOnlySettings.contains(r.data['key'])) Map<String, Object?>.from(r.data),
    ];
  }
  return out;
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late Directory tmp;
  late MemoryRemoteStore store;
  late CloudSync cloud;
  late Device a;
  late Device b;
  final info = BusinessInfo(id: 'b1', name: 'Shop', type: 'grocery', createdAt: DateTime(2026));

  Future<void> sync(Device d) =>
      cloud.sync(biz: info.id, engine: d.engine, deviceName: d.name, tempDir: tmp.path);

  Future<Product> product(Device d, String name) async => (await d.biz.products.search(name)).single;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('bk_sync_');
    store = MemoryRemoteStore();
    cloud = CloudSync(store);
    final bizA = Biz(AppDatabase(NativeDatabase.memory()));
    await seedBusiness(bizA, name: 'Shop', typeId: 'grocery', bangla: false);
    await bizA.products.create(const ProductInput(name: 'Rice', unit: 'kg', salePrice: 80, costPrice: 60), openingStock: 50);
    await bizA.products.create(const ProductInput(name: 'Oil', unit: 'pcs', salePrice: 200, costPrice: 170), openingStock: 20);
    a = Device(bizA, 'PC');
    await cloud.upload(info: info, engine: a.engine, deviceName: 'PC', tempDir: tmp.path);

    // Second device opens the business from the cloud.
    final path = p.join(tmp.path, 'device-b.sqlite');
    final join = await cloud.downloadSnapshot(info.id, path);
    final bizB = Biz(AppDatabase(NativeDatabase(File(path))));
    b = Device(bizB, 'Phone');
    await b.engine.adoptSnapshot(fromDevice: join.fromDevice, fromPushed: join.fromPushed, tag: join.tag);
    await cloud.registerDevice(info.id, b.engine, 'Phone');
  });

  tearDown(() async {
    await a.db.close();
    await b.db.close();
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  test('the second device starts with the same shop and its own ids and invoice letter', () async {
    expect(await dump(b.db), await dump(a.db));
    expect(await b.engine.deviceTag(), 'B');
    expect(b.db.idBase, greaterThanOrEqualTo(AppDatabase.idBlock));
    final rice = await product(b, 'Rice');
    final saleId = await b.biz.sales.createSale(
        lines: [CartLine(productId: rice.id, name: 'Rice', qty: 1, price: 80)], paid: 80, accountId: await cashId(b.biz));
    expect(saleId, greaterThan(b.db.idBase));
    expect((await b.biz.sales.byId(saleId))!.invoiceNo, startsWith('INV-B'));
  });

  test('work done on both devices ends up on both', () async {
    final riceA = await product(a, 'Rice');
    final oilB = await product(b, 'Oil');
    // PC: new customer on credit, a new product with stock, a sale.
    final cust = await a.biz.contacts.create(type: 'customer', name: 'Karim', phone: '01711000001');
    await a.biz.sales.createSale(
        lines: [CartLine(productId: riceA.id, name: 'Rice', qty: 5, price: 80)], contactId: cust, paid: 100, accountId: await cashId(a.biz));
    await a.biz.products.create(const ProductInput(name: 'Sugar', unit: 'kg', salePrice: 130), openingStock: 30);
    // Phone, at the same time: a sale and an expense.
    await b.biz.sales.createSale(
        lines: [CartLine(productId: oilB.id, name: 'Oil', qty: 3, price: 200)], paid: 600, accountId: await cashId(b.biz));
    await b.biz.expenses.add(category: 'Rent', amount: 500, accountId: await cashId(b.biz));

    await sync(a);
    await sync(b);
    await sync(a);

    expect(await dump(b.db), await dump(a.db));
    for (final d in [a, b]) {
      expect((await product(d, 'Rice')).stock, 45);
      expect((await product(d, 'Oil')).stock, 17);
      expect((await product(d, 'Sugar')).stock, 30);
      final karim = (await d.biz.contacts.search('customer', 'Karim')).single;
      expect(await d.biz.contacts.balanceOf(karim.id), 300);
    }
    final invoices = (await a.db.select(a.db.sales).get()).map((s) => s.invoiceNo).toList();
    expect(invoices.toSet().length, invoices.length, reason: 'no duplicate invoice numbers');
  });

  test('the same product sold on both devices comes off the stock twice', () async {
    final riceA = await product(a, 'Rice');
    final riceB = await product(b, 'Rice');
    await a.biz.sales.createSale(
        lines: [CartLine(productId: riceA.id, name: 'Rice', qty: 2, price: 80)], paid: 160, accountId: await cashId(a.biz));
    await b.biz.sales.createSale(
        lines: [CartLine(productId: riceB.id, name: 'Rice', qty: 7, price: 80)], paid: 560, accountId: await cashId(b.biz));
    await sync(a);
    await sync(b);
    await sync(a);
    expect((await product(a, 'Rice')).stock, 41);
    expect((await product(b, 'Rice')).stock, 41);
  });

  test('a rename made on one device survives a sale of that product on the other', () async {
    final rice = await product(b, 'Rice');
    await b.biz.products.update(
        rice.id, const ProductInput(name: 'Miniket Rice', unit: 'kg', salePrice: 85, costPrice: 60));
    await Future<void>.delayed(const Duration(milliseconds: 5));
    final riceA = await product(a, 'Rice');
    await a.biz.sales.createSale(
        lines: [CartLine(productId: riceA.id, name: 'Rice', qty: 1, price: 80)], paid: 80, accountId: await cashId(a.biz));
    await sync(b);
    await sync(a);
    await sync(b);
    for (final d in [a, b]) {
      final p = await product(d, 'Miniket');
      expect(p.salePrice, 85);
      expect(p.stock, 49);
    }
  });

  test('when both edit the same thing, the later edit wins everywhere', () async {
    final oilA = await product(a, 'Oil');
    final oilB = await product(b, 'Oil');
    await a.biz.products.update(oilA.id, const ProductInput(name: 'Soybean Oil', unit: 'pcs', salePrice: 210));
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await b.biz.products.update(oilB.id, const ProductInput(name: 'Teer Oil', unit: 'pcs', salePrice: 215));
    await sync(a);
    await sync(b);
    await sync(a);
    expect((await a.biz.products.byId(oilA.id))!.name, 'Teer Oil');
    expect((await b.biz.products.byId(oilA.id))!.name, 'Teer Oil');
  });

  test('deleting a khata entry removes it on the other device', () async {
    final c = await a.biz.contacts.create(type: 'customer', name: 'Rahim', phone: '01711000002');
    final entry = await a.biz.contacts.addEntry(contactId: c, gave: true, amount: 250);
    await sync(a);
    await sync(b);
    expect(await b.biz.contacts.balanceOf(c), 250);
    await a.biz.contacts.deleteEntry(entry);
    await sync(a);
    await sync(b);
    expect(await b.biz.contacts.balanceOf(c), 0);
  });

  test('syncing twice in a row changes nothing and uploads nothing', () async {
    await sync(a);
    await sync(b);
    final before = store.writes;
    await sync(a);
    await sync(b);
    expect(store.writes, before);
  });

  test('a device that missed cleaned-up changes is told to start again from a full copy', () async {
    final c = await a.biz.contacts.create(type: 'customer', name: 'One', phone: '01711000003');
    await sync(a);
    final first = (await store.list({'biz': 'b1', 'kind': 'chg'})).single;
    await a.biz.contacts.update(c, name: 'One more', phone: '01711000003');
    await sync(a);
    await store.delete(first);
    expect(() => sync(b), throwsA(isA<SyncException>().having((e) => e.code, 'code', 'resync_needed')));
  });

  test('a change from a newer app version is refused, not half-applied', () async {
    final cs = Changeset(
        schema: 99, device: 'zz', fromSeq: 1, toSeq: 1, createdAt: DateTime.now(), changes: const []);
    expect(() => a.engine.apply(cs), throwsA(isA<SyncException>().having((e) => e.code, 'code', 'update_app')));
  });

  test('ids from another device do not push this device off its own block', () async {
    final oil = await product(b, 'Oil');
    await b.biz.sales.createSale(
        lines: [CartLine(productId: oil.id, name: 'Oil', qty: 1, price: 200)], paid: 200, accountId: await cashId(b.biz));
    await sync(b);
    await sync(a);
    final rice = await product(a, 'Rice');
    final id = await a.biz.sales.createSale(
        lines: [CartLine(productId: rice.id, name: 'Rice', qty: 1, price: 80)], paid: 80, accountId: await cashId(a.biz));
    expect(id, lessThan(AppDatabase.idBlock), reason: 'the first device keeps using block 0');
  });

  test('without sync turned on nothing is logged', () async {
    final biz = Biz(AppDatabase(NativeDatabase.memory()));
    await seedBusiness(biz, name: 'Solo', typeId: 'grocery', bangla: false);
    await biz.products.create(const ProductInput(name: 'Tea', unit: 'pcs', salePrice: 10), openingStock: 5);
    expect(await SyncEngine(biz.db).pendingCount(), 0);
    await biz.db.close();
  });
}
