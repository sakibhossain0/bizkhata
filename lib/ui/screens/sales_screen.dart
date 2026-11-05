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

final _sales = StreamProvider.autoDispose.family<List<SaleRow>, (DateRange, String)>(
    (ref, a) => ref.watch(bizProvider).sales.watchList(range: a.$1, query: a.$2, channel: 'pos'));
final _summary = StreamProvider.autoDispose.family<SalesSummary, DateRange>(
    (ref, r) => ref.watch(bizProvider).reports.watchSales(r, channel: 'pos'));

class SalesScreen extends ConsumerStatefulWidget {
  const SalesScreen({super.key});
  @override
  ConsumerState<SalesScreen> createState() => _SalesScreenState();
}

class _SalesScreenState extends ConsumerState<SalesScreen> {
  RangeSelection range = RangeSelection.of(RangePreset.last30);
  String query = '';

  static const cols = [
    Col('', flex: 4),
    Col('', flex: 4),
    Col('', flex: 2, align: TextAlign.right),
    Col('', flex: 3, align: TextAlign.right),
    Col('', flex: 3, align: TextAlign.right),
    Col('', flex: 3, align: TextAlign.right),
  ];

  @override
  Widget build(BuildContext context) {
    final rows = ref.watch(_sales((range.range, query)));
    final sum = ref.watch(_summary(range.range)).value ?? const SalesSummary();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      PageHeader(
        title: T.sales.s,
        subtitle: range.label,
        actions: [
          SearchBox(hint: '${T.invoiceNo.s} / ${T.customer.s}', onChanged: (v) => setState(() => query = v), width: 240),
          RangeButton(value: range, onChanged: (r) => setState(() => range = r)),
          OutlinedButton.icon(
            onPressed: () => _export(context),
            icon: const Icon(Icons.download_rounded, size: 18),
            label: Text(T.exportCsv.s),
          ),
          FilledButton.icon(
            onPressed: () => context.go('/pos'),
            icon: const Icon(Icons.add_shopping_cart_rounded, size: 18),
            label: Text(T.newSale.s),
          ),
        ],
      ),
      Padding(
        padding: EdgeInsets.fromLTRB(context.gutter, 0, context.gutter, 14),
        child: AutoGrid(minItemWidth: 160, children: [
          StatTile(label: T.billCount.s, value: number(sum.count), icon: Icons.receipt_long_rounded, tone: Tone.brand),
          StatTile(label: T.total.s, value: money(sum.total), icon: Icons.payments_outlined, tone: Tone.accent),
          if (ref.watch(actorProvider).can(Cap.seeCost))
            StatTile(label: T.grossProfit.s, value: money(sum.grossProfit), icon: Icons.savings_outlined, tone: Tone.good),
          StatTile(label: T.due.s, value: money(sum.due), icon: Icons.hourglass_bottom_rounded, tone: Tone.bad),
        ]),
      ),
      Expanded(
        child: Container(
          margin: EdgeInsets.fromLTRB(context.gutter, 0, context.gutter, 24),
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(color: C.card, borderRadius: BorderRadius.circular(14), border: Border.all(color: C.line)),
          child: Column(children: [
            TableHead([
              Col(T.invoice.s, flex: 4),
              Col(T.customer.s, flex: 4),
              Col(T.items.s, flex: 2, align: TextAlign.right),
              Col(T.total.s, flex: 3, align: TextAlign.right),
              Col(T.paid.s, flex: 3, align: TextAlign.right),
              Col(T.status.s, flex: 3, align: TextAlign.right),
            ]),
            Expanded(
              child: AsyncView(rows, builder: (list) {
                if (list.isEmpty) return EmptyState(icon: Icons.receipt_long_outlined, text: T.noSalesYet.s);
                return ListView.builder(
                  itemCount: list.length,
                  itemBuilder: (_, i) {
                    final r = list[i];
                    return TableRowX(
                      cols: cols,
                      onTap: () => context.go('/sales/${r.sale.id}'),
                      cells: [
                        Cell2(r.sale.invoiceNo, friendlyDate(r.sale.date)),
                        Text(r.contactName ?? T.walkIn.s, style: r.contactName == null ? Txt.small : Txt.body, overflow: TextOverflow.ellipsis),
                        Text(number(r.itemCount), style: Txt.small),
                        MoneyText(r.sale.total),
                        MoneyText(r.sale.paid, style: Txt.num.copyWith(color: C.ink2, fontWeight: FontWeight.w500)),
                        r.sale.status != 'completed'
                            ? StatusPill(r.sale.status)
                            : r.due > 0
                                ? Pill('${T.due.s} ${money(r.due)}', tone: Tone.bad)
                                : Pill(T.st_completed.s, tone: Tone.good),
                      ],
                    );
                  },
                );
              }),
            ),
          ]),
        ),
      ),
    ]);
  }

  Future<void> _export(BuildContext context) async {
    final biz = ref.read(bizProvider);
    await guard(context, () async {
      final rows = await biz.reports.salesRegister(range.range);
      await saveCsv('sales-${fileStamp(DateTime.now())}', [
        ['Invoice', 'Date', 'Channel', 'Status', 'Customer', 'Subtotal', 'Discount', 'VAT', 'Delivery', 'Total', 'Paid', 'Due', 'Profit'],
        ...rows,
      ]);
    });
  }
}
