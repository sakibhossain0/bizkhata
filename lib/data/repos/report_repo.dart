import 'package:drift/drift.dart';

import '../../core/streams.dart';
import '../../core/util.dart';
import '../database.dart';

class SalesSummary {
  final int count;
  final double subtotal;
  final double discount;
  final double vat;
  final double delivery;
  final double total;
  final double paid;
  final double cost;
  const SalesSummary({
    this.count = 0,
    this.subtotal = 0,
    this.discount = 0,
    this.vat = 0,
    this.delivery = 0,
    this.total = 0,
    this.paid = 0,
    this.cost = 0,
  });

  /// Net goods revenue (after discount, excluding VAT and delivery).
  double get netSales => r2(subtotal - discount);
  double get grossProfit => r2(subtotal - discount + delivery - cost);
  double get due => r2(total - paid);
}

class DayPoint {
  final DateTime day;
  final double sales;
  final double profit;
  const DayPoint(this.day, this.sales, this.profit);
}

class ProductPerf {
  final int? productId;
  final String name;
  final double qty;
  final double revenue;
  final double profit;
  const ProductPerf(this.productId, this.name, this.qty, this.revenue, this.profit);
}

class ProfitLoss {
  final SalesSummary sales;
  final List<({String category, double total})> expenses;
  const ProfitLoss(this.sales, this.expenses);
  double get expenseTotal => r2(expenses.fold<double>(0, (s, e) => s + e.total));
  double get netProfit => r2(sales.grossProfit - expenseTotal);
}

class StockValue {
  final int items;
  final double atCost;
  final double atSale;
  final int lowCount;
  final int outCount;
  const StockValue(this.items, this.atCost, this.atSale, this.lowCount, this.outCount);
}

/// One account's day: what it started with, what moved, what it ends with.
typedef AccountDay = ({String account, double opening, double inflow, double outflow, double closing});

/// Everything the shopkeeper checks before closing for the day.
class DaySummary {
  final DateTime day;
  final int invoices;
  final double sales;
  final double grossProfit;
  final double paidAtSale;
  final double dueSales;
  final double dueCollected;
  final double codIn;
  final double otherIn;
  final double refunds;
  final double expenses;
  final double purchasePaid;
  final double supplierPaid;
  final double otherOut;
  final List<AccountDay> accounts;
  final List<({String who, int count, double total})> byStaff;
  const DaySummary({
    required this.day,
    this.invoices = 0,
    this.sales = 0,
    this.grossProfit = 0,
    this.paidAtSale = 0,
    this.dueSales = 0,
    this.dueCollected = 0,
    this.codIn = 0,
    this.otherIn = 0,
    this.refunds = 0,
    this.expenses = 0,
    this.purchasePaid = 0,
    this.supplierPaid = 0,
    this.otherOut = 0,
    this.accounts = const [],
    this.byStaff = const [],
  });

  double get moneyIn => r2(paidAtSale + dueCollected + codIn + otherIn);
  double get moneyOut => r2(refunds + expenses + purchasePaid + supplierPaid + otherOut);
  double get closing => r2(accounts.fold<double>(0, (s, a) => s + a.closing));
}

const _revenueSql = "status IN ('completed','delivered','partial')";

class ReportRepo {
  final AppDatabase db;
  ReportRepo(this.db);

  /// Day-end (Z) summary. Counter sales only for the sales lines; money lines
  /// come from the cash book, transfers between accounts excluded.
  Future<DaySummary> daySummary(DateTime day) async {
    final range = DateRange(dayStart(day), dayEnd(day));
    final sQ = db.customSelect(
      '''SELECT COUNT(*) AS n, SUM(total) AS tot, SUM(total - paid) AS due,
                SUM(subtotal - discount + delivery_charge - cost_total) AS gp
         FROM sales WHERE date BETWEEN ? AND ? AND channel = 'pos' AND $_revenueSql''',
      variables: _range(range),
    ).getSingle();
    final movesQ = db.customSelect(
      '''SELECT source, direction, SUM(amount) AS v FROM cash_txns
         WHERE date BETWEEN ? AND ? AND source <> 'transfer' GROUP BY source, direction''',
      variables: _range(range),
    ).get();
    final accQ = db.customSelect(
      '''SELECT a.name AS name, a.active AS act,
                a.opening + COALESCE((SELECT SUM(direction * amount) FROM cash_txns t WHERE t.account_id = a.id AND t.date < ?), 0) AS op,
                COALESCE((SELECT SUM(amount) FROM cash_txns t WHERE t.account_id = a.id AND t.direction = 1 AND t.date BETWEEN ? AND ?), 0) AS i,
                COALESCE((SELECT SUM(amount) FROM cash_txns t WHERE t.account_id = a.id AND t.direction = -1 AND t.date BETWEEN ? AND ?), 0) AS o
         FROM accounts a ORDER BY a.sort_order, a.id''',
      variables: [Variable.withDateTime(range.from), ..._range(range), ..._range(range)],
    ).get();
    final staffQ = db.customSelect(
      '''SELECT COALESCE(created_by, '') AS who, COUNT(*) AS n, SUM(total) AS tot FROM sales
         WHERE date BETWEEN ? AND ? AND channel = 'pos' AND $_revenueSql GROUP BY who ORDER BY tot DESC''',
      variables: _range(range),
    ).get();
    // Independent reads: run them together.
    final s = await sQ;
    final moves = await movesQ;
    final acc = await accQ;
    final staff = await staffQ;
    double sum(String source, int dir) => r2(moves
        .where((r) => r.read<String>('source') == source && r.read<int>('direction') == dir)
        .fold<double>(0, (a, r) => a + _d(r, 'v')));
    return DaySummary(
      day: range.from,
      invoices: s.read<int>('n'),
      sales: _d(s, 'tot'),
      grossProfit: _d(s, 'gp'),
      paidAtSale: sum('sale', 1),
      dueSales: _d(s, 'due'),
      dueCollected: sum('khata', 1),
      codIn: sum('cod', 1),
      otherIn: sum('manual_in', 1),
      refunds: r2(sum('refund', -1) - sum('refund', 1)),
      expenses: sum('expense', -1),
      purchasePaid: sum('purchase', -1),
      supplierPaid: sum('khata', -1),
      otherOut: sum('manual_out', -1),
      accounts: [
        // Archived accounts only when they still hold or moved money.
        for (final r in acc)
          if (r.read<bool>('act') || _d(r, 'op') != 0 || _d(r, 'i') != 0 || _d(r, 'o') != 0)
          (
            account: r.read<String>('name'),
            opening: _d(r, 'op'),
            inflow: _d(r, 'i'),
            outflow: _d(r, 'o'),
            closing: r2(_d(r, 'op') + _d(r, 'i') - _d(r, 'o')),
          ),
      ],
      byStaff: [for (final r in staff) (who: r.read<String>('who'), count: r.read<int>('n'), total: _d(r, 'tot'))],
    );
  }

  /// Counter sales per person over a period (owner's sales have no name).
  Stream<List<({String who, int count, double total})>> watchSalesByStaff(DateRange range) => db
      .customSelect(
        '''SELECT COALESCE(created_by, '') AS who, COUNT(*) AS n, SUM(total) AS tot FROM sales
           WHERE date BETWEEN ? AND ? AND channel = 'pos' AND $_revenueSql GROUP BY who ORDER BY tot DESC''',
        variables: _range(range),
        readsFrom: {db.sales},
      )
      .watch()
      .map((rows) => [for (final r in rows) (who: r.read<String>('who'), count: r.read<int>('n'), total: _d(r, 'tot'))]);

  List<Variable> _range(DateRange r) => [Variable.withDateTime(r.from), Variable.withDateTime(r.to)];

  static double _d(QueryRow r, String k) => r2(r.readNullable<double>(k) ?? 0);

  Stream<SalesSummary> watchSales(DateRange range, {String? channel}) {
    final ch = channel == null ? '' : ' AND channel = ?';
    return db
        .customSelect(
          '''SELECT COUNT(*) AS n, SUM(subtotal) AS sub, SUM(discount) AS disc, SUM(vat) AS vat,
                    SUM(delivery_charge) AS del, SUM(total) AS tot, SUM(paid) AS paid, SUM(cost_total) AS cost
             FROM sales WHERE date BETWEEN ? AND ? AND $_revenueSql$ch''',
          variables: [..._range(range), if (channel != null) Variable.withString(channel)],
          readsFrom: {db.sales},
        )
        .watchSingle()
        .map((r) => SalesSummary(
              count: r.read<int>('n'),
              subtotal: _d(r, 'sub'),
              discount: _d(r, 'disc'),
              vat: _d(r, 'vat'),
              delivery: _d(r, 'del'),
              total: _d(r, 'tot'),
              paid: _d(r, 'paid'),
              cost: _d(r, 'cost'),
            ));
  }

  Stream<double> watchExpenseTotal(DateRange range) => db
      .customSelect(
        'SELECT SUM(amount) AS v FROM expenses WHERE date BETWEEN ? AND ?',
        variables: _range(range),
        readsFrom: {db.expenses},
      )
      .watchSingle()
      .map((r) => _d(r, 'v'));

  /// One point per day, gaps filled with zero.
  Stream<List<DayPoint>> watchDaily(DateRange range) => db
          .customSelect(
            '''SELECT date(date, 'unixepoch', 'localtime') AS d, SUM(total) AS t,
                      SUM(subtotal - discount + delivery_charge - cost_total) AS p
               FROM sales WHERE date BETWEEN ? AND ? AND $_revenueSql
               GROUP BY d ORDER BY d''',
            variables: _range(range),
            readsFrom: {db.sales},
          )
          .watch()
          .map((rows) {
        final byDay = {for (final r in rows) r.read<String>('d'): (_d(r, 't'), _d(r, 'p'))};
        final out = <DayPoint>[];
        for (var d = dayStart(range.from); !d.isAfter(range.to); d = DateTime(d.year, d.month, d.day + 1)) {
          final key = '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
          final v = byDay[key];
          out.add(DayPoint(d, v?.$1 ?? 0, v?.$2 ?? 0));
        }
        return out;
      });

  Stream<List<ProductPerf>> watchTopProducts(DateRange range, {int limit = 10}) => db
      .customSelect(
        '''SELECT MAX(i.product_id) AS pid, i.name AS name, SUM(i.qty - i.returned_qty) AS qty,
                  SUM(i.total - i.price * i.returned_qty) AS rev,
                  SUM(i.total - i.price * i.returned_qty - (i.qty - i.returned_qty) * i.cost) AS profit
           FROM sale_items i JOIN sales s ON s.id = i.sale_id
           WHERE s.date BETWEEN ? AND ? AND s.$_revenueSql
           GROUP BY COALESCE(i.product_id, 'x' || i.name)
           ORDER BY rev DESC LIMIT $limit''',
        variables: _range(range),
        readsFrom: {db.sales, db.saleItems},
      )
      .watch()
      .map((rows) => rows
          .map((r) => ProductPerf(r.readNullable<int>('pid'), r.read<String>('name'), r3(r.read<double>('qty')),
              _d(r, 'rev'), _d(r, 'profit')))
          .toList());

  Stream<List<({String account, double amount})>> watchCollectionsByAccount(DateRange range) => db
      .customSelect(
        '''SELECT a.name AS name, SUM(t.amount) AS v FROM cash_txns t JOIN accounts a ON a.id = t.account_id
           WHERE t.date BETWEEN ? AND ? AND t.direction = 1 AND t.source IN ('sale','cod','khata')
           GROUP BY a.id ORDER BY v DESC''',
        variables: _range(range),
        readsFrom: {db.cashTxns, db.accounts},
      )
      .watch()
      .map((rows) => rows.map((r) => (account: r.read<String>('name'), amount: _d(r, 'v'))).toList());

  Stream<List<({String category, double total})>> watchExpensesByCategory(DateRange range) => db
      .customSelect(
        'SELECT category, SUM(amount) AS v FROM expenses WHERE date BETWEEN ? AND ? GROUP BY category ORDER BY v DESC',
        variables: _range(range),
        readsFrom: {db.expenses},
      )
      .watch()
      .map((rows) => rows.map((r) => (category: r.read<String>('category'), total: _d(r, 'v'))).toList());

  Stream<ProfitLoss> watchProfitLoss(DateRange range) =>
      combineLatest2(watchSales(range), watchExpensesByCategory(range), ProfitLoss.new);

  Stream<StockValue> watchStockValue() => db
      .customSelect(
        '''SELECT COUNT(*) AS n,
             SUM(CASE WHEN stock > 0 THEN stock * cost_price ELSE 0 END) AS cost,
             SUM(CASE WHEN stock > 0 THEN stock * sale_price ELSE 0 END) AS sale,
             SUM(CASE WHEN stock > 0 AND stock <= low_stock THEN 1 ELSE 0 END) AS low,
             SUM(CASE WHEN stock <= 0 THEN 1 ELSE 0 END) AS out_n
           FROM products WHERE active = 1 AND track_stock = 1''',
        readsFrom: {db.products},
      )
      .watchSingle()
      .map((r) => StockValue(r.read<int>('n'), _d(r, 'cost'), _d(r, 'sale'), r.readNullable<int>('low') ?? 0,
          r.readNullable<int>('out_n') ?? 0));

  Stream<List<({DateTime day, double cashIn, double cashOut})>> watchCashbook(DateRange range) => db
      .customSelect(
        '''SELECT date(date, 'unixepoch', 'localtime') AS d,
                  SUM(CASE WHEN direction = 1 THEN amount ELSE 0 END) AS i,
                  SUM(CASE WHEN direction = -1 THEN amount ELSE 0 END) AS o
           FROM cash_txns WHERE date BETWEEN ? AND ? AND source <> 'transfer'
           GROUP BY d ORDER BY d DESC''',
        variables: _range(range),
        readsFrom: {db.cashTxns},
      )
      .watch()
      .map((rows) => rows
          .map((r) => (day: DateTime.parse(r.read<String>('d')), cashIn: _d(r, 'i'), cashOut: _d(r, 'o')))
          .toList());

  /// Plain rows for CSV export of the sales register.
  Future<List<List<Object?>>> salesRegister(DateRange range) async {
    final rows = await db.customSelect(
      '''SELECT s.invoice_no, s.date, s.channel, s.status, COALESCE(c.name, s.ship_name, '') AS customer,
                s.subtotal, s.discount, s.vat, s.delivery_charge, s.total, s.paid, (s.total - s.paid) AS due,
                (s.subtotal - s.discount + s.delivery_charge - s.cost_total) AS profit
         FROM sales s LEFT JOIN contacts c ON c.id = s.contact_id
         WHERE s.date BETWEEN ? AND ? ORDER BY s.date''',
      variables: _range(range),
    ).get();
    return rows.map((r) {
      final d = DateTime.fromMillisecondsSinceEpoch(r.read<int>('date') * 1000);
      return <Object?>[
        r.read<String>('invoice_no'),
        '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')} ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}',
        r.read<String>('channel'),
        r.read<String>('status'),
        r.read<String>('customer'),
        _d(r, 'subtotal'),
        _d(r, 'discount'),
        _d(r, 'vat'),
        _d(r, 'delivery_charge'),
        _d(r, 'total'),
        _d(r, 'paid'),
        _d(r, 'due'),
        _d(r, 'profit'),
      ];
    }).toList();
  }
}
