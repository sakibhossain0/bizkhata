import 'package:drift/drift.dart';

import '../../core/util.dart';
import '../database.dart';

class ProductInput {
  final String name;
  final String? sku;
  final String? barcode;
  final int? categoryId;
  final String unit;
  final double costPrice;
  final double salePrice;
  final double wholesalePrice;
  final double lowStock;
  final bool trackStock;
  final String? description;
  final String? imagePath;

  const ProductInput({
    required this.name,
    this.sku,
    this.barcode,
    this.categoryId,
    this.unit = 'pcs',
    this.costPrice = 0,
    this.salePrice = 0,
    this.wholesalePrice = 0,
    this.lowStock = 0,
    this.trackStock = true,
    this.description,
    this.imagePath,
  });

  ProductsCompanion toCompanion() => ProductsCompanion(
        name: Value(name.trim()),
        sku: Value(_blank(sku)),
        barcode: Value(_blank(barcode)),
        categoryId: Value(categoryId),
        unit: Value(unit.trim().isEmpty ? 'pcs' : unit.trim()),
        costPrice: Value(r2(costPrice)),
        salePrice: Value(r2(salePrice)),
        wholesalePrice: Value(r2(wholesalePrice)),
        lowStock: Value(r3(lowStock)),
        trackStock: Value(trackStock),
        description: Value(_blank(description)),
        imagePath: Value(_blank(imagePath)),
        updatedAt: Value(DateTime.now()),
      );
}

String? _blank(String? s) => (s == null || s.trim().isEmpty) ? null : s.trim();

/// A unit must be a word (pcs, kg…). A bare number almost always means the
/// quantity was typed into the unit box by mistake.
bool isNumericUnit(String unit) => RegExp(r'^[\s0-9০-৯.,]+$').hasMatch(unit.trim());

void _validate(ProductInput input) {
  if (input.name.trim().isEmpty) throw BizException('name_required');
  if (input.unit.trim().isNotEmpty && isNumericUnit(input.unit)) throw BizException('unit_invalid');
}

enum StockFilter { all, low, out }

class ProductRepo {
  final AppDatabase db;
  ProductRepo(this.db);

  // ---------------- categories ----------------

  Stream<List<ProductCategory>> watchCategories() =>
      (db.select(db.categories)..orderBy([(t) => OrderingTerm.asc(t.name)])).watch();

  Future<int> addCategory(String name) async {
    final n = name.trim();
    if (n.isEmpty) throw BizException('name_required');
    final existing = await (db.select(db.categories)..where((t) => t.name.equals(n))).getSingleOrNull();
    if (existing != null) return existing.id;
    return db.into(db.categories).insert(CategoriesCompanion.insert(name: n));
  }

  Future<void> renameCategory(int id, String name) =>
      (db.update(db.categories)..where((t) => t.id.equals(id))).write(CategoriesCompanion(name: Value(name.trim())));

  Future<void> deleteCategory(int id) => (db.delete(db.categories)..where((t) => t.id.equals(id))).go();

  // ---------------- products ----------------

  Stream<List<Product>> watchProducts({String query = '', int? categoryId, StockFilter filter = StockFilter.all}) {
    final q = db.select(db.products)..where((t) => t.active.equals(true));
    final term = query.trim();
    if (term.isNotEmpty) {
      final like = '%$term%';
      q.where((t) => t.name.like(like) | t.sku.like(like) | t.barcode.equals(term));
    }
    if (categoryId != null) q.where((t) => t.categoryId.equals(categoryId));
    switch (filter) {
      case StockFilter.low:
        q.where((t) => t.trackStock.equals(true) & t.stock.isBiggerThanValue(0) & t.stock.isSmallerOrEqual(t.lowStock));
      case StockFilter.out:
        q.where((t) => t.trackStock.equals(true) & t.stock.isSmallerOrEqualValue(0));
      case StockFilter.all:
        break;
    }
    q.orderBy([(t) => OrderingTerm.asc(t.name)]);
    return q.watch();
  }

  Future<List<Product>> search(String query, {int limit = 30}) {
    final term = query.trim();
    final q = db.select(db.products)..where((t) => t.active.equals(true));
    if (term.isNotEmpty) {
      final like = '%$term%';
      q.where((t) => t.name.like(like) | t.sku.like(like) | t.barcode.equals(term));
    }
    q
      ..orderBy([(t) => OrderingTerm.asc(t.name)])
      ..limit(limit);
    return q.get();
  }

  Future<Product?> byId(int id) => (db.select(db.products)..where((t) => t.id.equals(id))).getSingleOrNull();

  Stream<Product?> watchById(int id) =>
      (db.select(db.products)..where((t) => t.id.equals(id))).watchSingleOrNull();

  /// Exact barcode or SKU match — what a USB barcode scanner types.
  Future<Product?> byCode(String code) async {
    final c = code.trim();
    if (c.isEmpty) return null;
    final rows = await (db.select(db.products)
          ..where((t) => t.active.equals(true) & (t.barcode.equals(c) | t.sku.equals(c)))
          ..limit(1))
        .get();
    return rows.isEmpty ? null : rows.first;
  }

  Future<int> create(ProductInput input, {double openingStock = 0, DateTime? openingDate}) => db.transaction(() async {
        _validate(input);
        await _checkUniqueCode(input.barcode, null);
        final id = await db.into(db.products).insert(input.toCompanion().copyWith(
              stock: Value(r3(openingStock)),
              createdAt: Value(DateTime.now()),
            ));
        if (openingStock != 0) {
          await db.into(db.stockMoves).insert(StockMovesCompanion.insert(
                productId: id,
                date: openingDate ?? DateTime.now(),
                qty: r3(openingStock),
                kind: 'opening',
              ));
        }
        return id;
      });

  Future<void> update(int id, ProductInput input) async {
    _validate(input);
    await _checkUniqueCode(input.barcode, id);
    await (db.update(db.products)..where((t) => t.id.equals(id))).write(input.toCompanion());
  }

  Future<void> _checkUniqueCode(String? barcode, int? selfId) async {
    final code = _blank(barcode);
    if (code == null) return;
    final clash = await (db.select(db.products)
          ..where((t) => t.barcode.equals(code) & t.active.equals(true))
          ..limit(1))
        .getSingleOrNull();
    if (clash != null && clash.id != selfId) throw BizException('barcode_exists');
  }

  /// Change stock by [delta] and log why. Used by manual adjustments.
  Future<void> adjustStock(int productId, double delta, {String kind = 'adjust', String? note, DateTime? date}) =>
      db.transaction(() async {
        if (delta == 0) return;
        await changeStock(productId, delta, kind: kind, note: note, date: date);
      });

  /// Set an absolute stock count (stock-take). Logs the difference.
  Future<void> setStock(int productId, double newQty, {String? note}) => db.transaction(() async {
        final p = await byId(productId);
        if (p == null) return;
        final delta = r3(newQty - p.stock);
        if (delta == 0) return;
        await changeStock(productId, delta, kind: 'adjust', note: note);
      });

  /// Low level: must be called inside a transaction by other repos too.
  Future<void> changeStock(int productId, double delta,
      {required String kind, String? refType, int? refId, String? note, DateTime? date}) async {
    await db.customUpdate(
      'UPDATE products SET stock = ROUND(stock + ?, 3), updated_at = ? WHERE id = ?',
      variables: [Variable.withReal(delta), Variable.withDateTime(DateTime.now()), Variable.withInt(productId)],
      updates: {db.products},
    );
    await db.into(db.stockMoves).insert(StockMovesCompanion.insert(
          productId: productId,
          date: date ?? DateTime.now(),
          qty: r3(delta),
          kind: kind,
          refType: Value(refType),
          refId: Value(refId),
          note: Value(note),
        ));
  }

  Stream<List<StockMove>> watchMoves(int productId, {int limit = 200}) => (db.select(db.stockMoves)
        ..where((t) => t.productId.equals(productId))
        ..orderBy([(t) => OrderingTerm.desc(t.date), (t) => OrderingTerm.desc(t.id)])
        ..limit(limit))
      .watch();

  /// Products with history are archived (kept for old invoices); brand new
  /// ones are removed outright.
  Future<void> delete(int id) => db.transaction(() async {
        final used = await db.customSelect(
          '''SELECT (SELECT COUNT(*) FROM sale_items WHERE product_id = ?1)
                  + (SELECT COUNT(*) FROM purchase_items WHERE product_id = ?1) AS n''',
          variables: [Variable.withInt(id)],
        ).getSingle();
        if (used.read<int>('n') > 0) {
          await (db.update(db.products)..where((t) => t.id.equals(id)))
              .write(const ProductsCompanion(active: Value(false)));
        } else {
          await (db.delete(db.products)..where((t) => t.id.equals(id))).go();
        }
      });

  Stream<List<Product>> watchLowStock({int limit = 50}) => (db.select(db.products)
        ..where((t) => t.active.equals(true) & t.trackStock.equals(true) & t.stock.isSmallerOrEqual(t.lowStock))
        ..orderBy([(t) => OrderingTerm.asc(t.stock)])
        ..limit(limit))
      .watch();

  static const importHeaders = [
    'name', 'category', 'unit', 'cost_price', 'sale_price', 'wholesale_price', 'stock', 'low_stock', 'sku', 'barcode'
  ];

  /// Bulk import from a CSV sheet (header row required, columns in any order).
  /// Rows whose barcode or SKU already exists update that product instead of
  /// creating a duplicate. Returns (created, updated, skipped).
  Future<({int created, int updated, int skipped})> importCsv(List<List<String>> rows) => db.transaction(() async {
        if (rows.isEmpty) return (created: 0, updated: 0, skipped: 0);
        final head = rows.first.map((h) => h.trim().toLowerCase().replaceAll(' ', '_')).toList();
        int col(String k) => head.indexOf(k);
        final idx = {for (final k in importHeaders) k: col(k)};
        if (idx['name']! < 0) throw BizException('name_required');
        String cell(List<String> r, String k) {
          final i = idx[k]!;
          return i >= 0 && i < r.length ? r[i].trim() : '';
        }

        var created = 0, updated = 0, skipped = 0;
        final catIds = <String, int>{};
        for (final r in rows.skip(1)) {
          final name = cell(r, 'name');
          if (name.isEmpty) {
            skipped++;
            continue;
          }
          final catName = cell(r, 'category');
          int? catId;
          if (catName.isNotEmpty) catId = catIds[catName] ??= await addCategory(catName);
          final barcode = cell(r, 'barcode');
          final sku = cell(r, 'sku');
          Product? existing;
          if (barcode.isNotEmpty) existing = await byCode(barcode);
          if (existing == null && sku.isNotEmpty) existing = await byCode(sku);
          final input = ProductInput(
            name: name,
            sku: sku,
            barcode: barcode,
            categoryId: catId ?? existing?.categoryId,
            unit: cell(r, 'unit').isEmpty || isNumericUnit(cell(r, 'unit')) ? (existing?.unit ?? 'pcs') : cell(r, 'unit'),
            costPrice: parseNum(cell(r, 'cost_price'), existing?.costPrice ?? 0),
            salePrice: parseNum(cell(r, 'sale_price'), existing?.salePrice ?? 0),
            wholesalePrice: parseNum(cell(r, 'wholesale_price'), existing?.wholesalePrice ?? 0),
            lowStock: parseNum(cell(r, 'low_stock'), existing?.lowStock ?? 0),
            trackStock: existing?.trackStock ?? true,
            description: existing?.description,
            imagePath: existing?.imagePath,
          );
          final stockText = cell(r, 'stock');
          if (existing != null) {
            await (db.update(db.products)..where((t) => t.id.equals(existing!.id))).write(input.toCompanion());
            if (stockText.isNotEmpty) {
              final delta = r3(parseNum(stockText) - existing.stock);
              if (delta != 0) await changeStock(existing.id, delta, kind: 'adjust', note: 'CSV import');
            }
            updated++;
          } else {
            await create(input, openingStock: parseNum(stockText));
            created++;
          }
        }
        return (created: created, updated: updated, skipped: skipped);
      });

  Stream<int> watchLowStockCount() => db
      .customSelect(
        'SELECT COUNT(*) AS n FROM products WHERE active = 1 AND track_stock = 1 AND stock <= low_stock',
        readsFrom: {db.products},
      )
      .watchSingle()
      .map((r) => r.read<int>('n'));
}
