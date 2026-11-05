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

final _purchases = StreamProvider.autoDispose.family<List<PurchaseRow>, (DateRange, String)>(
    (ref, a) => ref.watch(bizProvider).purchases.watchList(range: a.$1, query: a.$2));

class PurchasesScreen extends ConsumerStatefulWidget {
  const PurchasesScreen({super.key});
  @override
  ConsumerState<PurchasesScreen> createState() => _PurchasesScreenState();
}

class _PurchasesScreenState extends ConsumerState<PurchasesScreen> {
  RangeSelection range = RangeSelection.of(RangePreset.thisMonth);
  String query = '';

  static const cols = [
    Col('', flex: 3),
    Col('', flex: 4),
    Col('', flex: 2, align: TextAlign.right),
    Col('', flex: 3, align: TextAlign.right),
    Col('', flex: 3, align: TextAlign.right),
    Col('', flex: 3, align: TextAlign.right),
  ];

  @override
  Widget build(BuildContext context) {
    final rows = ref.watch(_purchases((range.range, query)));
    final list = rows.value ?? const <PurchaseRow>[];
    final active = list.where((r) => r.purchase.status == 'completed');
    final total = active.fold<double>(0, (s, r) => s + r.purchase.total);
    final due = active.fold<double>(0, (s, r) => s + r.due);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      PageHeader(
        title: T.purchases.s,
        subtitle: range.label,
        actions: [
          SearchBox(hint: '${T.purchaseNo.s} / ${T.supplier.s}', onChanged: (v) => setState(() => query = v), width: 230),
          RangeButton(value: range, onChanged: (r) => setState(() => range = r)),
          FilledButton.icon(
            onPressed: () => context.go('/purchases/new'),
            icon: const Icon(Icons.add_rounded, size: 19),
            label: Text(T.newPurchase.s),
          ),
        ],
      ),
      Padding(
        padding: EdgeInsets.fromLTRB(context.gutter, 0, context.gutter, 14),
        child: AutoGrid(minItemWidth: 160, children: [
          StatTile(label: T.billCount.s, value: number(active.length), icon: Icons.shopping_bag_outlined, tone: Tone.brand),
          StatTile(label: T.total.s, value: money(total), icon: Icons.payments_outlined, tone: Tone.accent),
          StatTile(label: T.due.s, value: money(due), icon: Icons.hourglass_bottom_rounded, tone: Tone.bad),
        ]),
      ),
      Expanded(
        child: Container(
          margin: EdgeInsets.fromLTRB(context.gutter, 0, context.gutter, 24),
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(color: C.card, borderRadius: BorderRadius.circular(14), border: Border.all(color: C.line)),
          child: Column(children: [
            TableHead([
              Col(T.purchaseNo.s, flex: 3),
              Col(T.supplier.s, flex: 4),
              Col(T.items.s, flex: 2, align: TextAlign.right),
              Col(T.total.s, flex: 3, align: TextAlign.right),
              Col(T.paid.s, flex: 3, align: TextAlign.right),
              Col(T.status.s, flex: 3, align: TextAlign.right),
            ]),
            Expanded(
              child: AsyncView(rows, builder: (list) {
                if (list.isEmpty) {
                  return EmptyState(
                    icon: Icons.shopping_bag_outlined,
                    text: T.noData.s,
                    action: FilledButton.icon(
                        onPressed: () => context.go('/purchases/new'),
                        icon: const Icon(Icons.add, size: 18),
                        label: Text(T.newPurchase.s)),
                  );
                }
                return ListView.builder(
                  itemCount: list.length,
                  itemBuilder: (_, i) {
                    final r = list[i];
                    return TableRowX(
                      cols: cols,
                      onTap: () => _detail(context, r.purchase.id),
                      cells: [
                        Cell2(r.purchase.refNo, friendlyDate(r.purchase.date)),
                        Text(r.supplierName ?? '—', style: Txt.body, overflow: TextOverflow.ellipsis),
                        Text(number(r.itemCount), style: Txt.small),
                        MoneyText(r.purchase.total),
                        MoneyText(r.purchase.paid, style: Txt.num.copyWith(color: C.ink2, fontWeight: FontWeight.w500)),
                        r.purchase.status == 'cancelled'
                            ? Pill(T.st_cancelled.s, tone: Tone.bad)
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

  Future<void> _detail(BuildContext context, int id) async {
    final biz = ref.read(bizProvider);
    final d = await biz.purchases.detail(id);
    if (d == null || !context.mounted) return;
    await showDialog(
      context: context,
      builder: (ctx) => AppDialog(
        title: '${d.purchase.refNo} · ${dateShort(d.purchase.date)}',
        icon: Icons.shopping_bag_outlined,
        width: 600,
        actions: [
          if (d.purchase.status == 'completed')
            TextButton.icon(
              style: TextButton.styleFrom(foregroundColor: C.outRed),
              onPressed: () async {
                final ok = await confirmDialog(ctx, title: T.cancelPurchase.s, message: T.cancelPurchaseConfirm.s, danger: true);
                if (ok && ctx.mounted) {
                  await guard(ctx, () => biz.purchases.cancel(id), success: T.saved.s);
                  if (ctx.mounted) Navigator.pop(ctx);
                }
              },
              icon: const Icon(Icons.undo_rounded, size: 18),
              label: Text(T.cancelPurchase.s),
            ),
          FilledButton(onPressed: () => Navigator.pop(ctx), child: Text(T.close.s)),
        ],
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (d.supplier != null) Text(d.supplier!.name, style: Txt.strong.copyWith(fontSize: 16)),
          const Gap(10),
          for (final it in d.items)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(children: [
                Expanded(child: Text(it.name, style: Txt.body)),
                Text('${qty(it.qty)} × ${money(it.unitCost)}', style: Txt.small),
                SizedBox(width: 110, child: Text(money(it.total), textAlign: TextAlign.right, style: Txt.num)),
              ]),
            ),
          const Divider(height: 20),
          if (d.purchase.discount > 0) _r(T.discount.s, '−${money(d.purchase.discount)}'),
          _r(T.total.s, money(d.purchase.total), bold: true),
          _r(T.paid.s, money(d.purchase.paid)),
          if (d.purchase.total - d.purchase.paid > 0) _r(T.due.s, money(d.purchase.total - d.purchase.paid), color: C.outRed),
          if (d.purchase.note != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text('${T.note.s}: ${d.purchase.note}', style: Txt.small)),
        ]),
      ),
    );
  }

  Widget _r(String k, String v, {bool bold = false, Color? color}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(children: [
          Text(k, style: bold ? Txt.strong : Txt.small),
          const Spacer(),
          Text(v, style: Txt.num.copyWith(color: color, fontWeight: bold ? FontWeight.w700 : FontWeight.w500)),
        ]),
      );
}
