import 'package:drift/drift.dart';

import '../../core/i18n.dart' show isBangla;
import '../../core/util.dart';
import '../database.dart';

class AccountBalance {
  final Account account;
  final double balance;
  const AccountBalance(this.account, this.balance);
}

class CashRepo {
  final AppDatabase db;
  CashRepo(this.db);

  Stream<List<Account>> watchAccounts({bool includeInactive = false}) {
    final q = db.select(db.accounts);
    if (!includeInactive) q.where((t) => t.active.equals(true));
    q.orderBy([(t) => OrderingTerm.asc(t.sortOrder), (t) => OrderingTerm.asc(t.id)]);
    return q.watch();
  }

  Future<List<Account>> accounts() => (db.select(db.accounts)
        ..where((t) => t.active.equals(true))
        ..orderBy([(t) => OrderingTerm.asc(t.sortOrder), (t) => OrderingTerm.asc(t.id)]))
      .get();

  Future<Account?> byId(int id) => (db.select(db.accounts)..where((t) => t.id.equals(id))).getSingleOrNull();

  Future<int> createAccount(String name, {String kind = 'cash', double opening = 0}) async {
    if (name.trim().isEmpty) throw BizException('name_required');
    final maxSort = await db.customSelect('SELECT COALESCE(MAX(sort_order), 0) AS m FROM accounts').getSingle();
    return db.insertRow(db.accounts, AccountsCompanion.insert(
          name: name.trim(),
          kind: Value(kind),
          opening: Value(r2(opening)),
          sortOrder: Value(maxSort.read<int>('m') + 1),
        ));
  }

  Future<void> updateAccount(int id, {required String name, required String kind, required double opening}) =>
      (db.update(db.accounts)..where((t) => t.id.equals(id))).write(AccountsCompanion(
        name: Value(name.trim()),
        kind: Value(kind),
        opening: Value(r2(opening)),
      ));

  Future<void> setAccountActive(int id, bool active) =>
      (db.update(db.accounts)..where((t) => t.id.equals(id))).write(AccountsCompanion(active: Value(active)));

  /// The account COD money lands in until the courier pays out. Created on
  /// first use so shops without online orders never see it.
  Future<int> ensureCourierAccount() async {
    final existing = await (db.select(db.accounts)
          ..where((t) => t.kind.equals('courier'))
          ..limit(1))
        .getSingleOrNull();
    if (existing != null) {
      if (!existing.active) await setAccountActive(existing.id, true);
      return existing.id;
    }
    return createAccount(isBangla ? 'কুরিয়ার ব্যালেন্স' : 'Courier balance', kind: 'courier');
  }

  Future<int> defaultCashAccount() async {
    final cash = await (db.select(db.accounts)
          ..where((t) => t.kind.equals('cash') & t.active.equals(true))
          ..orderBy([(t) => OrderingTerm.asc(t.sortOrder)])
          ..limit(1))
        .getSingleOrNull();
    if (cash != null) return cash.id;
    final any = await accounts();
    if (any.isNotEmpty) return any.first.id;
    return createAccount('Cash');
  }

  Stream<List<AccountBalance>> watchBalances() => db
      .customSelect(
        '''SELECT a.*, a.opening + COALESCE((SELECT SUM(direction * amount) FROM cash_txns t WHERE t.account_id = a.id), 0) AS bal
           FROM accounts a WHERE a.active = 1 ORDER BY a.sort_order, a.id''',
        readsFrom: {db.accounts, db.cashTxns},
      )
      .watch()
      .map((rows) => rows.map((r) => AccountBalance(db.accounts.map(r.data), r2(r.read<double>('bal')))).toList());

  Future<double> balanceOf(int accountId) async {
    final r = await db.customSelect(
      '''SELECT a.opening + COALESCE((SELECT SUM(direction * amount) FROM cash_txns t WHERE t.account_id = a.id), 0) AS bal
         FROM accounts a WHERE a.id = ?''',
      variables: [Variable.withInt(accountId)],
    ).getSingleOrNull();
    return r == null ? 0 : r2(r.read<double>('bal'));
  }

  /// Low level — other repos call this inside their own transaction.
  Future<int> add({
    required int accountId,
    required int direction,
    required double amount,
    required String source,
    String? refType,
    int? refId,
    int? contactId,
    String? note,
    DateTime? date,
  }) {
    assert(direction == 1 || direction == -1);
    return db.insertRow(db.cashTxns, CashTxnsCompanion.insert(
          accountId: accountId,
          date: date ?? DateTime.now(),
          direction: direction,
          amount: r2(amount.abs()),
          source: source,
          refType: Value(refType),
          refId: Value(refId),
          contactId: Value(contactId),
          note: Value(note),
          createdBy: Value(db.actor),
        ));
  }

  Future<void> deleteByRef(String refType, int refId) =>
      (db.delete(db.cashTxns)..where((t) => t.refType.equals(refType) & t.refId.equals(refId))).go();

  /// Owner puts money in / takes money out / other income / other payment.
  Future<int> manual({
    required int accountId,
    required bool cashIn,
    required double amount,
    String? note,
    DateTime? date,
  }) async {
    if (amount <= 0) throw BizException('amount_positive');
    return add(
      accountId: accountId,
      direction: cashIn ? 1 : -1,
      amount: amount,
      source: cashIn ? 'manual_in' : 'manual_out',
      note: note,
      date: date,
    );
  }

  /// Move money between accounts, e.g. courier payout into bank, bKash to cash.
  Future<void> transfer({required int fromId, required int toId, required double amount, String? note, DateTime? date}) =>
      db.transaction(() async {
        if (amount <= 0) throw BizException('amount_positive');
        if (fromId == toId) throw BizException('same_account');
        final when = date ?? DateTime.now();
        final outId = await add(
            accountId: fromId, direction: -1, amount: amount, source: 'transfer', note: note, date: when);
        await add(
            accountId: toId,
            direction: 1,
            amount: amount,
            source: 'transfer',
            refType: 'transfer',
            refId: outId,
            note: note,
            date: when);
        await (db.update(db.cashTxns)..where((t) => t.id.equals(outId)))
            .write(CashTxnsCompanion(refType: const Value('transfer'), refId: Value(outId)));
      });

  /// Only manual entries and transfers can be deleted from the cashbox;
  /// everything else is reversed through its document (sale, expense...).
  Future<void> deleteManual(int txnId) => db.transaction(() async {
        final t = await (db.select(db.cashTxns)..where((x) => x.id.equals(txnId))).getSingleOrNull();
        if (t == null) return;
        if (t.source == 'transfer' && t.refId != null) {
          await deleteByRef('transfer', t.refId!);
          await (db.delete(db.cashTxns)..where((x) => x.id.equals(t.refId!))).go();
          return;
        }
        if (t.source != 'manual_in' && t.source != 'manual_out') throw BizException('entry_locked');
        await (db.delete(db.cashTxns)..where((x) => x.id.equals(txnId))).go();
      });

  Stream<List<CashTxn>> watchTxns({int? accountId, required DateRange range, int limit = 500}) {
    final q = db.select(db.cashTxns)
      ..where((t) => t.date.isBetweenValues(range.from, range.to))
      ..orderBy([(t) => OrderingTerm.desc(t.date), (t) => OrderingTerm.desc(t.id)])
      ..limit(limit);
    if (accountId != null) q.where((t) => t.accountId.equals(accountId));
    return q.watch();
  }

  Stream<({double cashIn, double cashOut})> watchFlow({int? accountId, required DateRange range}) {
    final vars = <Variable>[Variable.withDateTime(range.from), Variable.withDateTime(range.to)];
    // Across all accounts a transfer is neither in nor out; for one account it is.
    var extra = " AND source <> 'transfer'";
    if (accountId != null) {
      extra = ' AND account_id = ?';
      vars.add(Variable.withInt(accountId));
    }
    return db
        .customSelect(
          '''SELECT COALESCE(SUM(CASE WHEN direction = 1 THEN amount END), 0) AS i,
                    COALESCE(SUM(CASE WHEN direction = -1 THEN amount END), 0) AS o
             FROM cash_txns WHERE date BETWEEN ? AND ?$extra''',
          variables: vars,
          readsFrom: {db.cashTxns},
        )
        .watchSingle()
        .map((r) => (cashIn: r2(r.read<double>('i')), cashOut: r2(r.read<double>('o'))));
  }
}
