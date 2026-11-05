import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/i18n.dart';
import '../../core/theme.dart';
import '../../data/biz.dart';
import '../../services/print_service.dart';
import '../../state/app_state.dart';
import 'common.dart';

/// Day-end (Z) summary with a day picker and a print button.
Future<void> showDayEnd(BuildContext context) => showDialog(context: context, builder: (_) => const _DayEndDialog());

class _DayEndDialog extends ConsumerStatefulWidget {
  const _DayEndDialog();
  @override
  ConsumerState<_DayEndDialog> createState() => _DayEndDialogState();
}

class _DayEndDialogState extends ConsumerState<_DayEndDialog> {
  DateTime day = DateTime.now();
  late Future<DaySummary> data = _load();

  Future<DaySummary> _load() => ref.read(bizProvider).reports.daySummary(day);

  void _go(DateTime d) => setState(() {
        day = d;
        data = _load();
      });

  @override
  Widget build(BuildContext context) {
    final seeCost = ref.watch(actorProvider).can(Cap.seeCost);
    final today = DateTime.now();
    final isToday = day.year == today.year && day.month == today.month && day.day == today.day;
    return AppDialog(
      title: T.dayEnd.s,
      icon: Icons.summarize_outlined,
      width: 560,
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(T.close.s)),
        FutureBuilder<DaySummary>(
          future: data,
          builder: (_, snap) => FilledButton.icon(
            onPressed: snap.data == null
                ? null
                : () async {
                    var direct = false;
                    final ok = await guard(context, () async {
                      direct = await PrintService.printDayEnd(context, ref.read(bizProvider), snap.data!, showProfit: seeCost);
                    });
                    if (ok && direct && context.mounted) toast(context, T.printed.s);
                  },
            icon: const Icon(Icons.print_outlined, size: 18),
            label: Text(T.printSummary.s),
          ),
        ),
      ],
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(T.dayEndHint.s, style: Txt.small),
        const Gap(10),
        Row(children: [
          IconButton(
            tooltip: T.back.s,
            onPressed: () => _go(day.subtract(const Duration(days: 1))),
            icon: const Icon(Icons.chevron_left_rounded),
          ),
          Expanded(
            child: TextButton.icon(
              onPressed: () async {
                final picked = await showDatePicker(
                    context: context, initialDate: day, firstDate: DateTime(2020), lastDate: today, helpText: T.pickDay.s);
                if (picked != null) _go(picked);
              },
              icon: const Icon(Icons.calendar_today_outlined, size: 17),
              label: Text(dateLong(day), style: Txt.strong.copyWith(fontSize: 15)),
            ),
          ),
          IconButton(
            tooltip: T.next.s,
            onPressed: isToday ? null : () => _go(day.add(const Duration(days: 1))),
            icon: const Icon(Icons.chevron_right_rounded),
          ),
        ]),
        const Gap(6),
        FutureBuilder<DaySummary>(
          future: data,
          builder: (_, snap) {
            if (snap.hasError) return Text(errorText(snap.error!), style: Txt.small.copyWith(color: C.outRed));
            final d = snap.data;
            if (d == null) return const Padding(padding: EdgeInsets.all(30), child: Loading());
            return _SummaryBody(d: d, showProfit: seeCost);
          },
        ),
      ]),
    );
  }
}

class _SummaryBody extends StatelessWidget {
  final DaySummary d;
  final bool showProfit;
  const _SummaryBody({required this.d, required this.showProfit});

  @override
  Widget build(BuildContext context) {
    Widget line(String k, double v, {bool strong = false, Color? color, bool skipZero = true}) {
      if (skipZero && v == 0 && !strong) return const SizedBox.shrink();
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 2.5),
        child: Row(children: [
          Expanded(child: Text(k, style: strong ? Txt.strong : Txt.body.copyWith(color: C.ink2))),
          Text(money(v), style: (strong ? Txt.strong : Txt.num).copyWith(color: color, fontSize: strong ? 15 : 14)),
        ]),
      );
    }

    Widget block(String title, List<Widget> children) => Container(
          margin: const EdgeInsets.only(top: 10),
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
          decoration: BoxDecoration(color: C.paper, borderRadius: BorderRadius.circular(12)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(title.toUpperCase(), style: Txt.caps),
            const Gap(6),
            ...children,
          ]),
        );

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      AutoGrid(minItemWidth: 150, gap: 10, children: [
        _Big(T.sales.s, money(d.sales), T.invoicesN.f({'n': number(d.invoices)})),
        _Big(T.moneyIn.s, money(d.moneyIn), null, color: C.inGreen),
        _Big(T.moneyOut.s, money(d.moneyOut), null, color: C.outRed),
      ]),
      block(T.sales.s, [
        line(T.sales.s, d.sales, strong: true),
        line(T.dueSales.s, d.dueSales),
        if (showProfit) line(T.grossProfit.s, d.grossProfit, color: d.grossProfit >= 0 ? C.inGreen : C.outRed),
      ]),
      block(T.moneyIn.s, [
        line(T.cashSales.s, d.paidAtSale),
        line(T.dueCollected.s, d.dueCollected),
        line(T.src_cod.s, d.codIn),
        line(T.src_manual_in.s, d.otherIn),
        line(T.moneyIn.s, d.moneyIn, strong: true, color: C.inGreen),
      ]),
      block(T.moneyOut.s, [
        line(T.expenses.s, d.expenses),
        line(T.purchasePaid.s, d.purchasePaid),
        line(T.supplierPaid.s, d.supplierPaid),
        line(T.refunds.s, d.refunds),
        line(T.src_manual_out.s, d.otherOut),
        line(T.moneyOut.s, d.moneyOut, strong: true, color: C.outRed),
      ]),
      block(T.closingBalance.s, [
        for (final a in d.accounts)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(children: [
              Expanded(child: Text(a.account, style: Txt.body)),
              Text('${money(a.opening, symbol: false)} + ${money(a.inflow, symbol: false)} − ${money(a.outflow, symbol: false)} = ',
                  style: Txt.tiny),
              Text(money(a.closing), style: Txt.strong),
            ]),
          ),
        const Divider(height: 14),
        line(T.closingBalance.s, d.closing, strong: true, skipZero: false),
      ]),
      if (d.byStaff.any((s) => s.who.isNotEmpty))
        block(T.salesByStaff.s, [
          for (final s in d.byStaff)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2.5),
              child: Row(children: [
                Expanded(child: Text(s.who.isEmpty ? T.role_owner.s : s.who, style: Txt.body)),
                Text('${T.invoicesN.f({'n': number(s.count)})}  ', style: Txt.tiny),
                Text(money(s.total), style: Txt.strong),
              ]),
            ),
        ]),
    ]);
  }
}

class _Big extends StatelessWidget {
  final String label;
  final String value;
  final String? sub;
  final Color? color;
  const _Big(this.label, this.value, this.sub, {this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(border: Border.all(color: C.line), borderRadius: BorderRadius.circular(12)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: Txt.label),
        const Gap(2),
        FittedBox(fit: BoxFit.scaleDown, child: Text(value, style: Txt.display(20, color: color ?? C.ink))),
        if (sub != null) Text(sub!, style: Txt.tiny),
      ]),
    );
  }
}
