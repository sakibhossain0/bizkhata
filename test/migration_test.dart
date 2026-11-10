import 'package:bizkhata/data/database.dart';
import 'package:drift/drift.dart' hide isNull;
import 'package:drift_dev/api/migrations_native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'generated_migrations/schema.dart';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late SchemaVerifier verifier;

  setUpAll(() {
    verifier = SchemaVerifier(GeneratedHelper());
  });

  for (final from in [1, 2, 3]) {
    test('v$from -> v4 produces exactly the v4 schema', () async {
      final connection = await verifier.startAt(from);
      final db = AppDatabase(connection);
      await verifier.migrateAndValidate(db, 4);
      await db.close();
    });
  }

  test('a v1 shop keeps its sales after upgrading', () async {
    final schema = await verifier.schemaAt(1);
    final raw = schema.rawDatabase;
    final now = DateTime(2026, 10, 1).millisecondsSinceEpoch ~/ 1000;
    raw.execute("INSERT INTO products (id, name, stock) VALUES (1, 'Rice', 40)");
    raw.execute("INSERT INTO sales (id, invoice_no, date, total) VALUES (1, 'INV-1', $now, 300)");
    raw.execute("INSERT INTO sale_items (sale_id, product_id, name, qty, price, total) VALUES (1, 1, 'Rice', 5, 60, 300)");

    final db = AppDatabase(schema.newConnection());
    final items = await db.select(db.saleItems).get();
    expect(items.single.qty, 5);
    expect(items.single.returnedQty, 0);
    final sale = await db.select(db.sales).getSingle();
    expect(sale.invoiceNo, 'INV-1');
    expect(sale.createdBy, isNull);
    expect(await db.select(db.users).get(), isEmpty);
    expect(await db.select(db.extLinks).get(), isEmpty);
    // Sync bookkeeping exists but stays off until the owner turns it on.
    final on = await db.customSelect("SELECT v FROM sync_state WHERE k = 'on'").getSingleOrNull();
    expect(on, isNull);
    await db.close();
  });

  test('website orders brought in before v4 count as in step with the website', () async {
    final schema = await verifier.schemaAt(3);
    final raw = schema.rawDatabase;
    final now = DateTime(2026, 11, 9).millisecondsSinceEpoch ~/ 1000;
    raw.execute("INSERT INTO sales (id, invoice_no, date, channel, status, total) VALUES (1, 'INV-1', $now, 'online', 'booked', 500)");
    raw.execute("INSERT INTO sales (id, invoice_no, date, channel, status, total) VALUES (2, 'INV-2', $now, 'online', 'pending', 300)");
    raw.execute("INSERT INTO ext_links (id, kind, source, ext_id, local_id) VALUES (1, 'order', 'web', 'w1', 1)");
    raw.execute("INSERT INTO ext_links (id, kind, source, ext_id, local_id) VALUES (2, 'order', 'web', 'w2', 2)");
    raw.execute("INSERT INTO ext_links (id, kind, source, ext_id, local_id) VALUES (3, 'product', 'web', 'p1', 7)");

    final db = AppDatabase(schema.newConnection());
    final links = {for (final l in await db.select(db.extLinks).get()) l.extId: l};
    expect(links['w1']!.extStatus, 'booked', reason: 'nothing old is sent back by surprise');
    expect(links['w2']!.extStatus, 'pending');
    expect(links['p1']!.extStatus, isNull, reason: 'only orders have a status');
    expect(links['w1']!.pushError, isNull);
    await db.close();
  });
}
