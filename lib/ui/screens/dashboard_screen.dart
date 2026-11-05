import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/format.dart';
import '../../core/i18n.dart';
import '../../core/theme.dart';
import '../../core/util.dart';
import '../../data/biz.dart';
import '../../state/app_state.dart';
import '../widgets/common.dart';
import '../widgets/day_end.dart';

final _todaySales = StreamProvider.autoDispose((ref) => ref.watch(bizProvider).reports.watchSales(DateRange.today()));
final _todayExpense = StreamProvider.autoDispose((ref) => ref.watch(bizProvider).reports.watchExpenseTotal(DateRange.today()));
final _monthPL = StreamProvider.autoDispose((ref) => ref.watch(bizProvider).reports.watchProfitLoss(DateRange.thisMonth()));
final _balances = StreamProvider.autoDispose((ref) => ref.watch(bizProvider).cash.watchBalances());
final _khata = StreamProvider.autoDispose((ref) => ref.watch(bizProvider).contacts.watchTotals());
final _daily = StreamProvider.autoDispose((ref) => ref.watch(bizProvider).reports.watchDaily(DateRange.lastDays(14)));
final _recent = StreamProvider.autoDispose((ref) => ref.watch(bizProvider).sales.watchListAll(limit: 7));
final _low = StreamProvider.autoDispose((ref) => ref.watch(bizProvider).products.watchLowStock(limit: 6));
final _orderCounts = StreamProvider.autoDispose((ref) => ref.watch(bizProvider).orders.watchStatusCounts());
final _codPending = StreamProvider.autoDispose((ref) => ref.watch(bizProvider).orders.watchCodPending());

class DashboardScreen extends ConsumerWidget {
  const DashboardScreen({super.key});

  String _greeting() {
    final h = DateTime.now().hour;
    if (h < 12) return T.goodMorning.s;
    if (h < 17) return T.goodAfternoon.s;
    return T.goodEvening.s;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionProvider);
    final settings = ref.watch(settingsProvider).value ?? const {};
    final online = settings.flag(K.onlineEnabled);
    final today = ref.watch(_todaySales).value ?? const SalesSummary();
    final exp = ref.watch(_todayExpense).value ?? 0;
    final balances = ref.watch(_balances).value ?? const <AccountBalance>[];
    final cashTotal = balances.fold<double>(0, (s, a) => s + a.balance);
    final topAccounts = [...balances]..sort((a, b) => b.balance.compareTo(a.balance));

    return LayoutBuilder(builder: (context, c) {
      final narrow = c.maxWidth < 1100;
      return ListView(
        padding: const EdgeInsets.only(bottom: 28),
        children: [
          PageHeader(
            title: '${_greeting()}, ${session.info.name}',
            subtitle: dateLong(DateTime.now()),
            actions: [
              OutlinedButton.icon(
                onPressed: () => showDayEnd(context),
                icon: const Icon(Icons.summarize_outlined, size: 18),
                label: Text(T.dayEnd.s),
              ),
              OutlinedButton.icon(
                onPressed: () => context.go('/customers'),
                icon: const Icon(Icons.menu_book_rounded, size: 18),
                label: Text(T.customers.s),
              ),
              FilledButton.icon(
                onPressed: () => context.go('/pos'),
                icon: const Icon(Icons.add_shopping_cart_rounded, size: 18),
                label: Row(mainAxisSize: MainAxisSize.min, children: [
                  Text(T.newSale.s),
                  const SizedBox(width: 8),
                  const KeyCap('F2', dark: true),
                ]),
              ),
            ],
          ),
          Padding(
            padding: EdgeInsets.symmetric(horizontal: context.gutter),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              _grid(narrow ? 2 : 4, [
                StatTile(
                  label: T.todaySales.s,
                  value: money(today.total),
                  icon: Icons.trending_up_rounded,
                  emphasize: true,
                  hint: T.billsCount.f({'n': number(today.count)}),
                  onTap: () => context.go('/sales'),
                ),
                StatTile(
                  label: T.todayProfit.s,
                  value: money(today.grossProfit),
                  icon: Icons.savings_outlined,
                  tone: Tone.good,
                  hint: today.netSales > 0 ? '${T.margin.s} ${pct(today.grossProfit / today.netSales * 100)}' : null,
                ),
                StatTile(
                  label: T.todayExpense.s,
                  value: money(exp),
                  icon: Icons.receipt_outlined,
                  tone: Tone.bad,
                  onTap: () => context.go('/expenses'),
                ),
                StatTile(
                  label: T.cashInHand.s,
                  value: money(cashTotal),
                  icon: Icons.account_balance_wallet_outlined,
                  tone: Tone.accent,
                  hint: topAccounts.take(2).map((a) => '${a.account.name} ${money(a.balance)}').join(' · '),
                  onTap: () => context.go('/cashbox'),
                ),
              ]),
              const SizedBox(height: 16),
              _row(narrow, [
                (2, const _KhataCard()),
                (3, const _ChartCard()),
              ]),
              const SizedBox(height: 16),
              _row(narrow, [
                (3, const _RecentSales()),
                (2, Column(children: [
                  if (online) ...[const _OrdersCard(), const SizedBox(height: 16)],
                  const _MonthCard(),
                  const SizedBox(height: 16),
                  const _LowStockCard(),
                ])),
              ]),
            ]),
          ),
        ],
      );
    });
  }

  Widget _grid(int cols, List<Widget> children) {
    return LayoutBuilder(builder: (context, c) {
      const gap = 14.0;
      final w = (c.maxWidth - gap * (cols - 1)) / cols;
      return Wrap(spacing: gap, runSpacing: gap, children: [for (final ch in children) SizedBox(width: w, child: ch)]);
    });
  }

  Widget _row(bool narrow, List<(int, Widget)> parts) {
    if (narrow) {
      return Column(children: [
        for (var i = 0; i < parts.length; i++) ...[if (i > 0) const SizedBox(height: 16), parts[i].$2],
      ]);
    }
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      for (var i = 0; i < parts.length; i++) ...[
        if (i > 0) const SizedBox(width: 16),
        Expanded(flex: parts[i].$1, child: parts[i].$2),
      ],
    ]);
  }
}

class _KhataCard extends ConsumerWidget {
  const _KhataCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(_khata).value ?? (receivable: 0.0, payable: 0.0);
    Widget half(String title, String hint, double v, Tone tone, String path, IconData icon) => Expanded(
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () => context.go(path),
            child: Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(color: tone.bg, borderRadius: BorderRadius.circular(12)),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Icon(icon, size: 16, color: tone.fg),
                  const SizedBox(width: 6),
                  Flexible(child: Text(title, style: Txt.strong.copyWith(color: tone.fg), overflow: TextOverflow.ellipsis)),
                ]),
                const SizedBox(height: 10),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(money(v), style: Txt.display(28, color: tone.fg)),
                ),
                const SizedBox(height: 4),
                Text(hint, style: Txt.tiny.copyWith(color: tone.fg.withValues(alpha: 0.8))),
              ]),
            ),
          ),
        );
    return Panel(
      title: T.sectionKhata.s,
      trailing: TextButton(onPressed: () => context.go('/customers'), child: Text(T.viewAll.s)),
      child: Row(children: [
        half(T.receivable.s, T.receivableHint.s, t.receivable, Tone.good, '/customers', Icons.south_west_rounded),
        const SizedBox(width: 12),
        half(T.payable.s, T.payableHint.s, t.payable, Tone.bad, '/suppliers', Icons.north_east_rounded),
      ]),
    );
  }
}

class _ChartCard extends ConsumerWidget {
  const _ChartCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(_daily).value ?? const <DayPoint>[];
    final maxY = data.fold<double>(0, (m, p) => p.sales > m ? p.sales : m);
    final total = data.fold<double>(0, (s, p) => s + p.sales);
    return Panel(
      title: T.salesTrend.s,
      trailing: Text(money(total), style: Txt.strong.copyWith(color: C.brand)),
      child: SizedBox(
        height: 168,
        child: data.isEmpty
            ? const Loading()
            : BarChart(
                BarChartData(
                  maxY: maxY == 0 ? 100 : maxY * 1.15,
                  alignment: BarChartAlignment.spaceAround,
                  borderData: FlBorderData(show: false),
                  gridData: FlGridData(
                    show: true,
                    drawVerticalLine: false,
                    horizontalInterval: maxY == 0 ? 25 : maxY * 1.15 / 4,
                    getDrawingHorizontalLine: (_) => const FlLine(color: C.line2, strokeWidth: 1),
                  ),
                  titlesData: FlTitlesData(
                    topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                    rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                    leftTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        reservedSize: 46,
                        interval: maxY == 0 ? 25 : maxY * 1.15 / 4,
                        getTitlesWidget: (v, meta) => v == meta.max
                            ? const SizedBox.shrink()
                            : Text(moneyShort(v), style: Txt.tiny),
                      ),
                    ),
                    bottomTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        reservedSize: 22,
                        getTitlesWidget: (v, meta) {
                          final i = v.toInt();
                          if (i < 0 || i >= data.length) return const SizedBox.shrink();
                          final d = data[i].day;
                          final isToday = i == data.length - 1;
                          return Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Text(digits('${d.day}'),
                                style: Txt.tiny.copyWith(
                                    color: isToday ? C.ink : C.ink3, fontWeight: isToday ? FontWeight.w700 : FontWeight.w400)),
                          );
                        },
                      ),
                    ),
                  ),
                  barTouchData: BarTouchData(
                    touchTooltipData: BarTouchTooltipData(
                      getTooltipColor: (_) => C.ink,
                      tooltipBorderRadius: BorderRadius.circular(8),
                      getTooltipItem: (group, _, rod, _) {
                        final p = data[group.x];
                        return BarTooltipItem(
                          '${dayMonth(p.day)}\n',
                          const TextStyle(fontFamily: kBody, color: Colors.white70, fontSize: 11.5),
                          children: [
                            TextSpan(
                                text: money(p.sales),
                                style: const TextStyle(fontFamily: kBody, color: Colors.white, fontWeight: FontWeight.w700, fontSize: 13.5)),
                            TextSpan(
                                text: '\n${T.profit.s} ${money(p.profit)}',
                                style: const TextStyle(fontFamily: kBody, color: Color(0xFF9BE3B9), fontSize: 11.5)),
                          ],
                        );
                      },
                    ),
                  ),
                  barGroups: [
                    for (var i = 0; i < data.length; i++)
                      BarChartGroupData(x: i, barRods: [
                        BarChartRodData(
                          toY: data[i].sales,
                          width: 14,
                          color: i == data.length - 1 ? C.marigold : C.brandMid,
                          borderRadius: const BorderRadius.vertical(top: Radius.circular(4)),
                        ),
                      ]),
                  ],
                ),
              ),
      ),
    );
  }
}

class _RecentSales extends ConsumerWidget {
  const _RecentSales();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rows = ref.watch(_recent);
    return Panel(
      title: T.recentSales.s,
      padding: const EdgeInsets.fromLTRB(0, 8, 0, 6),
      trailing: TextButton(onPressed: () => context.go('/sales'), child: Text(T.viewAll.s)),
      child: AsyncView(rows, builder: (list) {
        if (list.isEmpty) {
          return SizedBox(height: 220, child: EmptyState(icon: Icons.receipt_long_rounded, text: T.noSalesYet.s));
        }
        return Column(children: [
          for (final r in list)
            TableRowX(
              cols: const [Col('', flex: 4), Col('', flex: 3), Col('', flex: 3, align: TextAlign.right)],
              onTap: () => context.go(r.sale.channel == 'online' ? '/orders/${r.sale.id}' : '/sales/${r.sale.id}'),
              cells: [
                Row(children: [
                  Avatar(r.contactName ?? r.sale.shipName ?? T.walkIn.s,
                      size: 32, tone: r.sale.channel == 'online' ? Tone.info : Tone.brand),
                  const SizedBox(width: 10),
                  Expanded(child: Cell2(r.contactName ?? r.sale.shipName ?? T.walkIn.s, r.sale.invoiceNo)),
                ]),
                Cell2(friendlyDate(r.sale.date), itemsText(r.itemCount), Txt.small),
                Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                  MoneyText(r.sale.total),
                  const SizedBox(height: 2),
                  if (r.sale.channel == 'online' || r.sale.status != 'completed')
                    StatusPill(r.sale.status)
                  else if (r.due > 0)
                    Pill('${T.due.s} ${money(r.due)}', tone: Tone.bad),
                ]),
              ],
            ),
        ]);
      }),
    );
  }
}

class _LowStockCard extends ConsumerWidget {
  const _LowStockCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rows = ref.watch(_low);
    return Panel(
      title: T.lowStock.s,
      padding: const EdgeInsets.fromLTRB(0, 6, 0, 6),
      trailing: TextButton(onPressed: () => context.go('/products'), child: Text(T.viewAll.s)),
      child: AsyncView(rows, builder: (list) {
        if (list.isEmpty) {
          return Padding(
            padding: const EdgeInsets.all(18),
            child: Row(children: [
              const Icon(Icons.verified_outlined, color: C.inGreen, size: 20),
              const SizedBox(width: 10),
              Expanded(child: Text(T.allGood.s, style: Txt.small)),
            ]),
          );
        }
        return Column(children: [
          for (final p in list)
            TableRowX(
              cols: const [Col('', flex: 5), Col('', flex: 2, align: TextAlign.right)],
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 9),
              onTap: () => context.go('/products/${p.id}'),
              cells: [
                Text(p.name, style: Txt.body, maxLines: 1, overflow: TextOverflow.ellipsis),
                Pill(p.stock <= 0 ? T.outOfStock.s : '${qty(p.stock)} ${unitLabel(p.unit)}', tone: p.stock <= 0 ? Tone.bad : Tone.warn),
              ],
            ),
        ]);
      }),
    );
  }
}

class _MonthCard extends ConsumerWidget {
  const _MonthCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pl = ref.watch(_monthPL).value;
    final net = pl?.netProfit ?? 0;
    return Panel(
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(T.monthSales.s, style: Txt.label),
            const SizedBox(height: 6),
            Text(money(pl?.sales.total ?? 0), style: Txt.display(22)),
          ]),
        ),
        Container(width: 1, height: 44, color: C.line2),
        const SizedBox(width: 16),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(T.monthNetProfit.s, style: Txt.label),
            const SizedBox(height: 6),
            Text(money(net), style: Txt.display(22, color: net >= 0 ? C.inGreen : C.outRed)),
          ]),
        ),
      ]),
    );
  }
}

class _OrdersCard extends ConsumerWidget {
  const _OrdersCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final counts = ref.watch(_orderCounts).value ?? const {};
    final cod = ref.watch(_codPending).value ?? 0;
    Widget stat(String status) => Expanded(
          child: Column(children: [
            Text(number(counts[status] ?? 0), style: Txt.display(22, color: statusTone(status).fg)),
            const SizedBox(height: 2),
            Text(tKey('st', status), style: Txt.tiny, textAlign: TextAlign.center),
          ]),
        );
    return Panel(
      title: T.orders.s,
      trailing: TextButton(onPressed: () => context.go('/orders'), child: Text(T.open.s)),
      child: Column(children: [
        Row(children: [stat('pending'), stat('confirmed'), stat('booked'), stat('delivered')]),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(color: C.infoSoft, borderRadius: BorderRadius.circular(10)),
          child: Row(children: [
            const Icon(Icons.local_shipping_outlined, size: 18, color: C.info),
            const SizedBox(width: 8),
            Expanded(child: Text(T.codWithCourier.s, style: Txt.small.copyWith(color: C.info))),
            Text(money(cod), style: Txt.strong.copyWith(color: C.info)),
          ]),
        ),
      ]),
    );
  }
}
