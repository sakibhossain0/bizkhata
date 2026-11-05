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
import '../widgets/pickers.dart';

class _PLine {
  final int? productId;
  final String name;
  final String? unit;
  final double oldCost;
  final double oldPrice;
  final TextEditingController qty = TextEditingController(text: '1');
  final TextEditingController cost;
  final TextEditingController newPrice = TextEditingController();
  _PLine({this.productId, required this.name, this.unit, this.oldCost = 0, this.oldPrice = 0})
      : cost = TextEditingController(text: oldCost == 0 ? '' : (oldCost == oldCost.roundToDouble() ? '${oldCost.toInt()}' : '$oldCost'));

  PurchaseLine get line => PurchaseLine(
        productId: productId,
        name: name,
        qty: parseNum(qty.text, 0),
        unitCost: parseNum(cost.text),
        newSalePrice: newPrice.text.trim().isEmpty ? null : parseNum(newPrice.text),
      );

  void dispose() {
    qty.dispose();
    cost.dispose();
    newPrice.dispose();
  }
}

class PurchaseFormScreen extends ConsumerStatefulWidget {
  const PurchaseFormScreen({super.key});
  @override
  ConsumerState<PurchaseFormScreen> createState() => _PurchaseFormScreenState();
}

class _PurchaseFormScreenState extends ConsumerState<PurchaseFormScreen> {
  final lines = <_PLine>[];
  final discount = TextEditingController();
  final paid = TextEditingController();
  final note = TextEditingController();
  Contact? supplier;
  int? accountId;
  DateTime date = DateTime.now();

  @override
  void initState() {
    super.initState();
    Future.microtask(() async {
      final id = await ref.read(bizProvider).cash.defaultCashAccount();
      if (mounted) setState(() => accountId = id);
    });
  }

  @override
  void dispose() {
    for (final l in lines) {
      l.dispose();
    }
    discount.dispose();
    paid.dispose();
    note.dispose();
    super.dispose();
  }

  double get subtotal => lines.fold<double>(0, (s, l) => s + l.line.total);
  double get total => r2((subtotal - parseNum(discount.text)).clamp(0, double.infinity));

  Future<void> _save() async {
    final biz = ref.read(bizProvider);
    final paidAmt = paid.text.trim().isEmpty ? total : parseNum(paid.text);
    final now = DateTime.now();
    final ok = await guard(context, () async {
      await biz.purchases.create(
        lines: lines.map((l) => l.line).toList(),
        supplierId: supplier?.id,
        discount: parseNum(discount.text),
        paid: paidAmt,
        accountId: paidAmt > 0 ? accountId : null,
        note: note.text,
        date: DateTime(date.year, date.month, date.day, now.hour, now.minute),
      );
    }, success: T.purchaseSaved.s);
    if (ok && mounted) context.go('/purchases');
  }

  @override
  Widget build(BuildContext context) {
    final t = total;
    final paidAmt = paid.text.trim().isEmpty ? t : parseNum(paid.text);
    final due = r2(t - paidAmt);
    return ListView(padding: const EdgeInsets.only(bottom: 28), children: [
      PageHeader(
        leading: IconButton(onPressed: () => context.go('/purchases'), icon: const Icon(Icons.arrow_back_rounded)),
        title: T.newPurchase.s,
        actions: [BusyButton(label: T.save.s, icon: Icons.check_rounded, onPressed: _save)],
      ),
      Padding(
        padding: EdgeInsets.symmetric(horizontal: context.gutter),
        child: AdaptiveRow(children: [
          Expanded(
            flex: 5,
            child: Panel(
              title: T.items.s,
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                ProductSearchField(
                  autofocus: true,
                  onPick: (p) => setState(() {
                    if (!lines.any((l) => l.productId == p.id)) {
                      lines.add(_PLine(productId: p.id, name: p.name, unit: p.unit, oldCost: p.costPrice, oldPrice: p.salePrice));
                    }
                  }),
                ),
                const Gap(12),
                if (lines.isEmpty)
                  Padding(padding: const EdgeInsets.all(24), child: Center(child: Text(T.e_cart_empty.s, style: Txt.small)))
                else
                  for (final l in lines)
                    Container(
                      margin: const EdgeInsets.only(bottom: 10),
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(color: C.paper, borderRadius: BorderRadius.circular(12)),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                        Row(children: [
                          Expanded(child: Text(l.name, style: Txt.strong)),
                          Text(money(l.line.total), style: Txt.num),
                          IconButton(
                            onPressed: () => setState(() {
                              lines.remove(l);
                              l.dispose();
                            }),
                            icon: const Icon(Icons.close_rounded, size: 18, color: C.ink3),
                          ),
                        ]),
                        const Gap(6),
                        FieldRow(children: [NumField(controller: l.qty, label: T.qty.s, suffix: unitLabel(l.unit), onChanged: (_) => setState(() {})), NumField(
                              controller: l.cost,
                              label: T.unitCost.s,
                              prefix: '৳ ',
                              onChanged: (_) => setState(() {}),
                              helper: l.oldCost > 0 ? '${T.cost.s}: ${money(l.oldCost)}' : null,
                            ), NumField(
                              controller: l.newPrice,
                              label: '${T.newSalePrice.s} (${T.optional.s})',
                              prefix: '৳ ',
                              helper: l.oldPrice > 0 ? '${T.salePrice.s}: ${money(l.oldPrice)}' : null,
                            )]),
                      ]),
                    ),
              ]),
            ),
          ),
          const Gap(16),
          Expanded(
            flex: 3,
            child: Column(children: [
              Panel(
                title: T.supplier.s,
                child: InkWell(
                  onTap: () async {
                    final c = await pickContact(context, 'supplier');
                    if (c != null) setState(() => supplier = c);
                  },
                  borderRadius: BorderRadius.circular(10),
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(color: supplier == null ? C.paper : C.brandSoft, borderRadius: BorderRadius.circular(10)),
                    child: Row(children: [
                      Avatar(supplier?.name ?? '?', tone: supplier == null ? Tone.neutral : Tone.brand),
                      const Gap(10),
                      Expanded(child: Text(supplier?.name ?? T.noSupplier.s, style: Txt.strong)),
                      if (supplier != null)
                        IconButton(onPressed: () => setState(() => supplier = null), icon: const Icon(Icons.close_rounded, size: 18))
                      else
                        const Icon(Icons.chevron_right_rounded, color: C.ink3),
                    ]),
                  ),
                ),
              ),
              const Gap(16),
              Panel(
                title: T.paid.s,
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Row(children: [
                    Expanded(child: NumField(controller: discount, label: T.discount.s, prefix: '৳ ', onChanged: (_) => setState(() {}))),
                    const Gap(10),
                    OutlinedButton.icon(
                      onPressed: () async {
                        final d = await showDatePicker(context: context, firstDate: DateTime(2015), lastDate: DateTime.now(), initialDate: date);
                        if (d != null) setState(() => date = d);
                      },
                      icon: const Icon(Icons.event_outlined, size: 18),
                      label: Text(dateShort(date)),
                    ),
                  ]),
                  const Gap(12),
                  Row(children: [
                    Text(T.total.s, style: Txt.strong),
                    const Spacer(),
                    Text(money(t), style: Txt.display(24, color: C.brand)),
                  ]),
                  const Gap(12),
                  NumField(controller: paid, label: '${T.paid.s} (${money(t)})', prefix: '৳ ', onChanged: (_) => setState(() {})),
                  const Gap(10),
                  if (paidAmt > 0) AccountChips(value: accountId, onChanged: (v) => setState(() => accountId = v)),
                  if (due > 0) ...[
                    const Gap(10),
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(color: C.outSoft, borderRadius: BorderRadius.circular(9)),
                      child: Row(children: [
                        Expanded(
                          child: Text(supplier == null ? T.e_due_needs_supplier.s : T.dueToKhata.s,
                              style: Txt.small.copyWith(color: C.outRed, fontWeight: FontWeight.w600)),
                        ),
                        Text(money(due), style: Txt.strong.copyWith(color: C.outRed)),
                      ]),
                    ),
                  ],
                  const Gap(12),
                  TextIn(controller: note, label: T.noteOptional.s),
                ]),
              ),
            ]),
          ),
        ]),
      ),
    ]);
  }
}
