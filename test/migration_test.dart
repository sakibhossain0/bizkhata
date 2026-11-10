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

  for (final from in [1, 2]) {
    test('v$from -> v3 produces exactly the v3 schema', () async {
      final connection = await verifier.startAt(from);
      final db = AppDatabase(connection);
      await verifier.migrateAndValidate(db, 3);
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
}
