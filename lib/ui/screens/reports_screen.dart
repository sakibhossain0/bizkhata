import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/format.dart';
import '../../core/i18n.dart';
import '../../core/theme.dart';
import '../../core/util.dart';
import '../../data/biz.dart';
import '../../services/messaging.dart';
import '../../state/app_state.dart';
import '../widgets/common.dart';
import '../widgets/day_end.dart';

final _sales = StreamProvider.autoDispose.family<SalesSummary, DateRange>((ref, r) => ref.watch(bizProvider).reports.watchSales(r));
final _daily = StreamProvider.autoDispose.family<List<DayPoint>, DateRange>((ref, r) => ref.watch(bizProvider).reports.watchDaily(r));
final _byAccount = StreamProvider.autoDispose.family<List<({String account, double amount})>, DateRange>(
    (ref, r) => ref.watch(bizProvider).reports.watchCollectionsByAccount(r));
final _pl = StreamProvider.autoDispose.family<ProfitLoss, DateRange>((ref, r) => ref.watch(bizProvider).reports.watchProfitLoss(r));
final _top = StreamProvider.autoDispose.family<List<ProductPerf>, DateRange>(
    (ref, r) => ref.watch(bizProvider).reports.watchTopProducts(r, limit: 50));
final _stockValue = StreamProvider.autoDispose((ref) => ref.watch(bizProvider).reports.watchStockValue());
final _lowList = StreamProvider.autoDispose((ref) => ref.watch(bizProvider).products.watchLowStock(limit: 200));
final _dues = StreamProvider.autoDispose.family<List<ContactWithBalance>, String>((ref, type) =>
    ref.watch(bizProvider).contacts.watchContacts(type, sort: ContactSort.balanceDesc, onlyWithBalance: true));
final _expCats = StreamProvider.autoDispose.family<List<({String category, double total})>, DateRange>(
    (ref, r) => ref.watch(bizProvider).reports.watchExpensesByCategory(r));
final _byStaff = StreamProvider.autoDispose.family<List<({String who, int count, double total})>, DateRange>(
    (ref, r) => ref.watch(bizProvider).reports.watchSalesByStaff(r));
final _cashbook = StreamProvider.autoDispose.family<List<({DateTime day, double cashIn, double cashOut})>, DateRange>(
    (ref, r) => ref.watch(bizProvider).reports.watchCashbook(r));

class ReportsScreen extends ConsumerStatefulWidget {
  const ReportsScreen({super.key});
  @override
  ConsumerState<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends ConsumerState<ReportsScreen> with SingleTickerProviderStateMixin {
  late final tabs = TabController(length: 8, vsync: this)..addListener(() => setState(() {}));
  RangeSelection range = RangeSelection.of(RangePreset.thisMonth);

  @override
  void dispose() {
    tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final r = range.range;
    final ranged = tabs.index != 3 && tabs.index != 4;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      PageHeader(
        title: T.reports.s,
        subtitle: ranged ? range.label : null,
        actions: [
          if (ranged) RangeButton(value: range, onChanged: (v) => setState(() => range = v)),
          OutlinedButton.icon(
            onPressed: () => showDayEnd(context),
            icon: const Icon(Icons.summarize_outlined, size: 18),
            label: Text(T.dayEnd.s),
          ),
          OutlinedButton.icon(
            onPressed: () => _export(context),
            icon: const Icon(Icons.download_rounded, size: 18),
            label: Text(T.exportCsv.s),
          ),
        ],
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18),
        child: TabBar(
          controller: tabs,
          isScrollable: true,
          tabs: [
            Tab(text: T.salesReport.s),
            Tab(text: T.profitLoss.s),
            Tab(text: T.topSelling.s),
            Tab(text: T.stockReport.s),
            Tab(text: T.dueReport.s),
            Tab(text: T.expenseReport.s),
            Tab(text: T.cashbook.s),
            Tab(text: T.byStaff.s),
          ],
        ),
      ),
      Expanded(
        child: TabBarView(controller: tabs, children: [
          _SalesTab(range: r),
          _PLTab(range: r),
          _TopTab(range: r),
          const _StockTab(),
          const _DueTab(),
          _ExpenseTab(range: r),
          _CashbookTab(range: r),
          _StaffTab(range: r),
        ]),
      ),
    ]);
  }

  Future<void> _export(BuildContext context) async {
    final biz = ref.read(bizProvider);
    final r = range.range;
    final stamp = fileStamp(DateTime.now());
    await guard(context, () async {
      switch (tabs.index) {
        case 0:
          await saveCsv('sales-register-$stamp', [
            ['Invoice', 'Date', 'Channel', 'Status', 'Customer', 'Subtotal', 'Discount', 'VAT', 'Delivery', 'Total', 'Paid', 'Due', 'Profit'],
            ...await biz.reports.salesRegister(r),
          ]);
        case 1:
          final pl = await biz.reports.watchProfitLoss(r).first;
          await saveCsv('profit-loss-$stamp', [
            ['Item', 'Amount'],
            ['Net sales', pl.sales.netSales],
            ['Delivery charges collected', pl.sales.delivery],
            ['Cost of goods sold', -pl.sales.cost],
            ['Gross profit', pl.sales.grossProfit],
            for (final e in pl.expenses) ['Expense: ${e.category}', -e.total],
            ['Net profit', pl.netProfit],
          ]);
        case 2:
          final top = await biz.reports.watchTopProducts(r, limit: 1000).first;
          await saveCsv('top-products-$stamp', [
            ['Product', 'Qty sold', 'Revenue', 'Profit'],
            for (final p in top) [p.name, p.qty, p.revenue, p.profit],
          ]);
        case 3:
          final all = await biz.products.watchProducts().first;
          await saveCsv('stock-$stamp', [
            ['Product', 'SKU', 'Barcode', 'Unit', 'Stock', 'Cost price', 'Sale price', 'Stock value (cost)', 'Stock value (sale)'],
            for (final p in all)
              [p.name, p.sku, p.barcode, p.unit, p.stock, p.costPrice, p.salePrice, r2(p.stock * p.costPrice), r2(p.stock * p.salePrice)],
          ]);
        case 4:
          final c = await biz.contacts.watchContacts('customer', onlyWithBalance: true).first;
          final s = await biz.contacts.watchContacts('supplier', onlyWithBalance: true).first;
          await saveCsv('due-list-$stamp', [
            ['Type', 'Name', 'Phone', 'Receivable', 'Payable'],
            for (final x in [...c, ...s])
              [x.contact.type, x.contact.name, x.contact.phone, x.balance > 0 ? x.balance : 0, x.balance < 0 ? -x.balance : 0],
          ]);
        case 5:
          final list = await biz.expenses.watchExpenses(range: r).first;
          await saveCsv('expenses-$stamp', [
            ['Date', 'Category', 'Amount', 'Note'],
            for (final e in list) [e.date.toIso8601String().substring(0, 10), e.category, e.amount, e.note],
          ]);
        case 6:
          final days = await biz.reports.watchCashbook(r).first;
          await saveCsv('cashbook-$stamp', [
            ['Date', 'Money in', 'Money out', 'Net'],
            for (final d in days) [d.day.toIso8601String().substring(0, 10), d.cashIn, d.cashOut, r2(d.cashIn - d.cashOut)],
          ]);
      }
    });
  }
}

Widget _pad(BuildContext context, Widget child) =>
    SingleChildScrollView(padding: EdgeInsets.fromLTRB(context.gutter, 18, context.gutter, 28), child: child);

class _SalesTab extends ConsumerWidget {
  final DateRange range;
  const _SalesTab({required this.range});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(_sales(range)).value ?? const SalesSummary();
    final daily = ref.watch(_daily(range)).value ?? const <DayPoint>[];
    final accounts = ref.watch(_byAccount(range)).value ?? const [];
    final maxY = daily.fold<double>(0, (m, p) => p.sales > m ? p.sales : m);
    return _pad(context, Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Wrap(spacing: 12, runSpacing: 12, children: [
        for (final (l, v, i, t) in [
          (T.billCount.s, number(s.count), Icons.receipt_long_rounded, Tone.brand),
          (T.total.s, money(s.total), Icons.payments_outlined, Tone.accent),
          (T.netSales.s, money(s.netSales), Icons.sell_outlined, Tone.info),
          (T.grossProfit.s, money(s.grossProfit), Icons.savings_outlined, Tone.good),
          (T.avgBill.s, money(s.count == 0 ? 0 : s.total / s.count), Icons.functions_rounded, Tone.neutral),
          (T.due.s, money(s.due), Icons.hourglass_bottom_rounded, Tone.bad),
        ])
          SizedBox(width: 220, child: StatTile(label: l, value: v, icon: i, tone: t)),
      ]),
      const Gap(16),
      AdaptiveRow(children: [
        Expanded(
          flex: 3,
          child: Panel(
            title: T.dailySales.s,
            child: SizedBox(
              height: 240,
              child: daily.isEmpty
                  ? const Loading()
                  : LineChart(LineChartData(
                      minY: 0,
                      maxY: maxY == 0 ? 100 : maxY * 1.15,
                      borderData: FlBorderData(show: false),
                      gridData: FlGridData(
                        drawVerticalLine: false,
                        getDrawingHorizontalLine: (_) => const FlLine(color: C.line2, strokeWidth: 1),
                      ),
                      titlesData: FlTitlesData(
                        topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                        rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                        leftTitles: AxisTitles(
                          sideTitles: SideTitles(
                            showTitles: true,
                            reservedSize: 50,
                            getTitlesWidget: (v, meta) => v == meta.max ? const SizedBox.shrink() : Text(moneyShort(v), style: Txt.tiny),
                          ),
                        ),
                        bottomTitles: AxisTitles(
                          sideTitles: SideTitles(
                            showTitles: true,
                            reservedSize: 24,
                            interval: (daily.length / 7).ceilToDouble().clamp(1, 1000),
                            getTitlesWidget: (v, _) {
                              final i = v.toInt();
                              if (i < 0 || i >= daily.length) return const SizedBox.shrink();
                              return Padding(padding: const EdgeInsets.only(top: 6), child: Text(dayMonth(daily[i].day), style: Txt.tiny));
                            },
                          ),
                        ),
                      ),
                      lineTouchData: LineTouchData(
                        touchTooltipData: LineTouchTooltipData(
                          getTooltipColor: (_) => C.ink,
                          getTooltipItems: (spots) => spots
                              .map((sp) => LineTooltipItem(
                                    '${dayMonth(daily[sp.x.toInt()].day)}\n${money(sp.y)}',
                                    TextStyle(
                                        fontFamily: kBody,
                                        color: sp.barIndex == 0 ? Colors.white : const Color(0xFF9BE3B9),
                                        fontWeight: FontWeight.w600,
                                        fontSize: 12),
                                  ))
                              .toList(),
                        ),
                      ),
                      lineBarsData: [
                        LineChartBarData(
                          spots: [for (var i = 0; i < daily.length; i++) FlSpot(i.toDouble(), daily[i].sales)],
                          isCurved: true,
                          curveSmoothness: 0.2,
                          color: C.brandMid,
                          barWidth: 2.6,
                          dotData: const FlDotData(show: false),
                          belowBarData: BarAreaData(show: true, color: C.brandMid.withValues(alpha: 0.08)),
                        ),
                        LineChartBarData(
                          spots: [for (var i = 0; i < daily.length; i++) FlSpot(i.toDouble(), daily[i].profit)],
                          isCurved: true,
                          curveSmoothness: 0.2,
                          color: C.marigold,
                          barWidth: 2,
                          dashArray: [5, 4],
                          dotData: const FlDotData(show: false),
                        ),
                      ],
                    )),
            ),
          ),
        ),
        const Gap(16),
        Expanded(
          flex: 2,
          child: Panel(
            title: T.collectionsByAccount.s,
            child: Column(children: [
              if (accounts.isEmpty) Text(T.noData.s, style: Txt.small),
              for (final a in accounts)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Row(children: [
                    Expanded(child: Text(a.account, style: Txt.body)),
                    MoneyText(a.amount),
                  ]),
                ),
            ]),
          ),
        ),
      ]),
    ]));
  }
}

class _PLTab extends ConsumerWidget {
  final DateRange range;
  const _PLTab({required this.range});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pl = ref.watch(_pl(range));
    return AsyncView(pl, builder: (p) {
      final net = p.netProfit;
      Widget row(String k, double v, {bool bold = false, bool minus = false, Color? color, double indent = 0}) => Padding(
            padding: EdgeInsets.fromLTRB(indent, 7, 0, 7),
            child: Row(children: [
              Expanded(child: Text(k, style: bold ? Txt.strong.copyWith(fontSize: 15) : Txt.body)),
              Text('${minus ? '−' : ''}${money(v)}',
                  style: (bold ? Txt.display(18) : Txt.num).copyWith(color: color ?? (bold ? C.ink : C.ink2))),
            ]),
          );
      return _pad(context, Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 680),
          child: Panel(
            padding: const EdgeInsets.fromLTRB(26, 18, 26, 22),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text(T.profitLoss.s, style: Txt.display(22)),
              Text(range.days == 1 ? dateShort(range.from) : '${dateShort(range.from)} – ${dateShort(range.to)}', style: Txt.small),
              const Gap(14),
              row(T.netSales.s, p.sales.netSales),
              row(T.deliveryIncome.s, p.sales.delivery),
              row(T.cogs.s, p.sales.cost, minus: true),
              const Divider(height: 16),
              row(T.grossProfit.s, p.sales.grossProfit, bold: true),
              const Gap(8),
              Text(T.lessExpenses.s, style: Txt.label),
              for (final e in p.expenses) row(e.category, e.total, minus: true, indent: 14),
              if (p.expenses.isEmpty) Padding(padding: const EdgeInsets.all(8), child: Text(T.noData.s, style: Txt.small)),
              const Divider(height: 20),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(color: net >= 0 ? C.inSoft : C.outSoft, borderRadius: BorderRadius.circular(12)),
                child: Row(children: [
                  Expanded(child: Text(net >= 0 ? T.netProfit.s : T.netLoss.s, style: Txt.strong.copyWith(fontSize: 17, color: net >= 0 ? C.inGreen : C.outRed))),
                  Text(money(net.abs()), style: Txt.display(28, color: net >= 0 ? C.inGreen : C.outRed)),
                ]),
              ),
            ]),
          ),
        ),
      ));
    });
  }
}

class _TopTab extends ConsumerWidget {
  final DateRange range;
  const _TopTab({required this.range});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final top = ref.watch(_top(range));
    const cols = [Col('', flex: 1), Col('', flex: 6), Col('', flex: 2, align: TextAlign.right), Col('', flex: 3, align: TextAlign.right), Col('', flex: 3, align: TextAlign.right)];
    return _pad(context, Panel(
      padding: EdgeInsets.zero,
      child: Column(children: [
        TableHead([
          const Col('#', flex: 1),
          Col(T.productName.s, flex: 6),
          Col(T.qtySold.s, flex: 2, align: TextAlign.right),
          Col(T.revenue.s, flex: 3, align: TextAlign.right),
          Col(T.profit.s, flex: 3, align: TextAlign.right),
        ]),
        AsyncView(top, builder: (list) {
          if (list.isEmpty) return SizedBox(height: 180, child: EmptyState(icon: Icons.bar_chart_rounded, text: T.noData.s));
          final maxRev = list.first.revenue;
          return Column(children: [
            for (var i = 0; i < list.length; i++)
              TableRowX(
                cols: cols,
                onTap: list[i].productId == null ? null : () => context.go('/products/${list[i].productId}'),
                cells: [
                  Text(digits('${i + 1}'), style: Txt.small),
                  Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(list[i].name, style: Txt.strong),
                    const Gap(4),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(3),
                      child: LinearProgressIndicator(
                        value: maxRev == 0 ? 0 : list[i].revenue / maxRev,
                        minHeight: 4,
                        backgroundColor: C.paper2,
                        color: C.brandMid,
                      ),
                    ),
                  ]),
                  Text(qty(list[i].qty), style: Txt.small),
                  MoneyText(list[i].revenue),
                  MoneyText(list[i].profit, tone: list[i].profit >= 0 ? Tone.good : Tone.bad),
                ],
              ),
          ]);
        }),
      ]),
    ));
  }
}

class _StockTab extends ConsumerWidget {
  const _StockTab();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final v = ref.watch(_stockValue).value;
    final low = ref.watch(_lowList).value ?? const <Product>[];
    return _pad(context, Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Wrap(spacing: 12, runSpacing: 12, children: [
        SizedBox(width: 220, child: StatTile(label: T.stockItems.s, value: number(v?.items ?? 0), icon: Icons.inventory_2_outlined, tone: Tone.brand)),
        SizedBox(width: 220, child: StatTile(label: T.stockValueCost.s, value: money(v?.atCost ?? 0), icon: Icons.account_balance_outlined, tone: Tone.info)),
        SizedBox(width: 220, child: StatTile(label: T.stockValueSale.s, value: money(v?.atSale ?? 0), icon: Icons.sell_outlined, tone: Tone.accent)),
        SizedBox(
            width: 220,
            child: StatTile(
                label: T.potentialProfit.s, value: money((v?.atSale ?? 0) - (v?.atCost ?? 0)), icon: Icons.savings_outlined, tone: Tone.good)),
      ]),
      const Gap(16),
      Panel(
        title: '${T.lowStock.s} / ${T.outOfStock.s}',
        padding: const EdgeInsets.only(top: 8, bottom: 8),
        child: Column(children: [
          if (low.isEmpty) Padding(padding: const EdgeInsets.all(18), child: Text(T.allGood.s, style: Txt.small)),
          for (final p in low)
            TableRowX(
              cols: const [Col('', flex: 6), Col('', flex: 3, align: TextAlign.right), Col('', flex: 3, align: TextAlign.right)],
              onTap: () => context.go('/products/${p.id}'),
              cells: [
                Text(p.name, style: Txt.strong),
                Text('${T.lowStockAlert.s}: ${qty(p.lowStock)}', style: Txt.tiny),
                Pill(p.stock <= 0 ? T.outOfStock.s : '${qty(p.stock)} ${unitLabel(p.unit)}', tone: p.stock <= 0 ? Tone.bad : Tone.warn),
              ],
            ),
        ]),
      ),
    ]));
  }
}

class _DueTab extends ConsumerWidget {
  const _DueTab();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    Widget list(String type) {
      final rows = ref.watch(_dues(type)).value ?? const <ContactWithBalance>[];
      final total = rows.fold<double>(0, (s, r) => s + r.balance.abs());
      final isC = type == 'customer';
      return Panel(
        title: isC ? T.totalReceivable.s : T.totalPayable.s,
        trailing: Text(money(total), style: Txt.display(18, color: isC ? C.inGreen : C.outRed)),
        padding: const EdgeInsets.only(top: 8, bottom: 8),
        child: Column(children: [
          if (rows.isEmpty) Padding(padding: const EdgeInsets.all(18), child: Text(T.noData.s, style: Txt.small)),
          for (final r in rows)
            TableRowX(
              cols: const [Col('', flex: 6), Col('', flex: 3, align: TextAlign.right)],
              onTap: () => context.go('${isC ? '/customers' : '/suppliers'}/${r.contact.id}'),
              cells: [
                Cell2(r.contact.name, r.contact.phone == null ? null : digits(r.contact.phone!)),
                MoneyText(r.balance.abs(), tone: r.balance > 0 ? Tone.good : Tone.bad),
              ],
            ),
        ]),
      );
    }

    return _pad(context, AdaptiveRow(children: [
      Expanded(child: list('customer')),
      const Gap(16),
      Expanded(child: list('supplier')),
    ]));
  }
}

class _StaffTab extends ConsumerWidget {
  final DateRange range;
  const _StaffTab({required this.range});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rows = ref.watch(_byStaff(range)).value ?? const [];
    final total = rows.fold<double>(0, (s, r) => s + r.total);
    const cols = [Col('', flex: 6), Col('', flex: 3, align: TextAlign.right), Col('', flex: 3, align: TextAlign.right)];
    return _pad(
      context,
      Panel(
        title: T.salesByStaff.s,
        trailing: Text(money(total), style: Txt.display(18)),
        padding: const EdgeInsets.only(top: 8, bottom: 8),
        child: Column(children: [
          TableHead([
            Col(T.staff.s, flex: 6),
            Col(T.invoices.s, flex: 3, align: TextAlign.right),
            Col(T.total.s, flex: 3, align: TextAlign.right),
          ]),
          if (rows.isEmpty) Padding(padding: const EdgeInsets.all(18), child: Text(T.noData.s, style: Txt.small)),
          for (final r in rows)
            TableRowX(cols: cols, cells: [
              Row(children: [
                Avatar(r.who.isEmpty ? T.role_owner.s : r.who, size: 30),
                const Gap(10),
                Expanded(child: Text(r.who.isEmpty ? T.role_owner.s : r.who, style: Txt.strong, overflow: TextOverflow.ellipsis)),
              ]),
              Text(number(r.count), style: Txt.small),
              MoneyText(r.total),
            ]),
        ]),
      ),
    );
  }
}

class _ExpenseTab extends ConsumerWidget {
  final DateRange range;
  const _ExpenseTab({required this.range});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rows = ref.watch(_expCats(range)).value ?? const [];
    final total = rows.fold<double>(0, (s, r) => s + r.total);
    return _pad(context, Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 680),
        child: Panel(
          title: T.totalExpense.s,
          trailing: Text(money(total), style: Txt.display(20, color: C.outRed)),
          child: Column(children: [
            if (rows.isEmpty) Text(T.noData.s, style: Txt.small),
            for (final r in rows)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 7),
                child: Row(children: [
                  Expanded(child: Text(r.category, style: Txt.body)),
                  SizedBox(width: 60, child: Text(pct(total == 0 ? 0 : r.total / total * 100), textAlign: TextAlign.right, style: Txt.tiny)),
                  SizedBox(width: 130, child: Text(money(r.total), textAlign: TextAlign.right, style: Txt.num)),
                ]),
              ),
          ]),
        ),
      ),
    ));
  }
}

class _CashbookTab extends ConsumerWidget {
  final DateRange range;
  const _CashbookTab({required this.range});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final days = ref.watch(_cashbook(range)).value ?? const [];
    const cols = [Col('', flex: 4), Col('', flex: 3, align: TextAlign.right), Col('', flex: 3, align: TextAlign.right), Col('', flex: 3, align: TextAlign.right)];
    return _pad(context, Panel(
      padding: EdgeInsets.zero,
      child: Column(children: [
        TableHead([
          Col(T.date.s, flex: 4),
          Col(T.moneyIn.s, flex: 3, align: TextAlign.right),
          Col(T.moneyOut.s, flex: 3, align: TextAlign.right),
          Col(T.balance.s, flex: 3, align: TextAlign.right),
        ]),
        if (days.isEmpty) SizedBox(height: 160, child: EmptyState(icon: Icons.menu_book_outlined, text: T.noData.s)),
        for (final d in days)
          TableRowX(cols: cols, cells: [
            Text(dateLong(d.day), style: Txt.body),
            MoneyText(d.cashIn, tone: Tone.good),
            MoneyText(d.cashOut, tone: Tone.bad),
            MoneyText(d.cashIn - d.cashOut, signed: true),
          ]),
      ]),
    ));
  }
}
