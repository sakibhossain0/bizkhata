import 'package:drift/drift.dart';

import '../../core/util.dart';
import '../database.dart';
import 'cash_repo.dart';

class ExpenseRepo {
  final AppDatabase db;
  final CashRepo cash;
  ExpenseRepo(this.db, this.cash);

  Stream<List<ExpenseCategory>> watchCategories() =>
      (db.select(db.expenseCategories)..orderBy([(t) => OrderingTerm.asc(t.name)])).watch();

  Future<void> ensureCategory(String name) async {
    final n = name.trim();
    if (n.isEmpty) return;
    await db.insertRow(db.expenseCategories, 
          ExpenseCategoriesCompanion.insert(name: n),
          mode: InsertMode.insertOrIgnore,
        );
  }

  Future<void> deleteCategory(int id) => (db.delete(db.expenseCategories)..where((t) => t.id.equals(id))).go();

  Future<int> add({
    required String category,
    required double amount,
    int? accountId,
    String? note,
    DateTime? date,
    String? refType,
    int? refId,
  }) =>
      db.transaction(() => addInTx(
            category: category,
            amount: amount,
            accountId: accountId,
            note: note,
            date: date,
            refType: refType,
            refId: refId,
          ));

  /// For callers already inside a transaction (courier fees on orders).
  Future<int> addInTx({
    required String category,
    required double amount,
    int? accountId,
    String? note,
    DateTime? date,
    String? refType,
    int? refId,
  }) async {
    final amt = r2(amount);
    if (amt <= 0) throw BizException('amount_positive');
    if (category.trim().isEmpty) throw BizException('category_required');
    final when = date ?? DateTime.now();
    await ensureCategory(category);
    final id = await db.insertRow(db.expenses, ExpensesCompanion.insert(
          date: when,
          category: category.trim(),
          amount: amt,
          accountId: Value(accountId),
          note: Value(note),
          refType: Value(refType),
          refId: Value(refId),
          createdBy: Value(db.actor),
        ));
    if (accountId != null) {
      await cash.add(
        accountId: accountId,
        direction: -1,
        amount: amt,
        source: 'expense',
        refType: 'expense',
        refId: id,
        note: '${category.trim()}${note == null || note.isEmpty ? '' : ' · $note'}',
        date: when,
      );
    }
    return id;
  }

  Future<void> delete(int id) => db.transaction(() async {
        await cash.deleteByRef('expense', id);
        await (db.delete(db.expenses)..where((t) => t.id.equals(id))).go();
      });

  Stream<List<Expense>> watchExpenses({required DateRange range, String? category}) {
    final q = db.select(db.expenses)
      ..where((t) => t.date.isBetweenValues(range.from, range.to))
      ..orderBy([(t) => OrderingTerm.desc(t.date), (t) => OrderingTerm.desc(t.id)]);
    if (category != null) q.where((t) => t.category.equals(category));
    return q.watch();
  }

  Stream<List<({String category, double total})>> watchByCategory(DateRange range) => db
      .customSelect(
        '''SELECT category, SUM(amount) AS total FROM expenses
           WHERE date BETWEEN ? AND ? GROUP BY category ORDER BY total DESC''',
        variables: [Variable.withDateTime(range.from), Variable.withDateTime(range.to)],
        readsFrom: {db.expenses},
      )
      .watch()
      .map((rows) => rows.map((r) => (category: r.read<String>('category'), total: r2(r.read<double>('total')))).toList());
}
