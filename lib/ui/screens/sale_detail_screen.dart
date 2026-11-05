import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/format.dart';
import '../../core/i18n.dart';
import '../../core/theme.dart';
import '../../core/util.dart';
import '../../data/biz.dart';
import '../../services/messaging.dart';
import '../../services/print_service.dart';
import '../../services/templates.dart';
import '../../state/app_state.dart';
import '../widgets/common.dart';

final saleDetailProvider = StreamProvider.autoDispose.family<SaleDetail?, int>((ref, id) => ref.watch(bizProvider).sales.watchDetail(id));

class SaleDetailScreen extends ConsumerWidget {
  final int id;
  const SaleDetailScreen({super.key, required this.id});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final d = ref.watch(saleDetailProvider(id));
    final biz = ref.watch(bizProvider);
    final actor = ref.watch(actorProvider);
    final settings = ref.watch(settingsProvider).value ?? const {};
    return AsyncView(d, builder: (detail) {
      if (detail == null) return EmptyState(icon: Icons.receipt_long_outlined, text: T.e_not_found.s);
      final s = detail.sale;
      if (s.channel == 'online') {
        WidgetsBinding.instance.addPostFrameCallback((_) => context.go('/orders/${s.id}'));
        return const Loading();
      }
      final profit = s.subtotal - s.discount + s.deliveryCharge - s.costTotal;
      final fullyReturned = s.status == 'returned';
      final partReturned = !fullyReturned && detail.items.any((i) => i.returnedQty > 0);
      // A sale returned in steps keeps its last remaining figures, so show the lines that made them up.
      final steppedReturn = fullyReturned && detail.items.any((i) => i.returnedQty < i.qty);
      final returnedValue = r2(detail.items.fold<double>(0, (a, i) => a + i.price * i.returnedQty));
      final phone = detail.contact?.phone ?? s.shipPhone;
      return ListView(padding: const EdgeInsets.only(bottom: 28), children: [
        PageHeader(
          leading: IconButton(onPressed: () => context.go('/sales'), icon: const Icon(Icons.arrow_back_rounded)),
          title: s.invoiceNo,
          subtitle: dateLong(s.date),
          actions: [
            StatusPill(s.status),
            if (partReturned) Pill(T.st_partial_return.s, tone: Tone.warn),
            _PrintButton(onPrint: (paper) => _print(context, biz, s.id, paper)),
            PopupMenuButton<String>(
              tooltip: T.share.s,
              position: PopupMenuPosition.under,
              onSelected: (v) async {
                final text = invoiceMessage(settings, detail);
                switch (v) {
                  case 'wa':
                    await Messaging.whatsapp(phone ?? '', text);
                  case 'img':
                    if (context.mounted) await guard(context, () => PrintService.shareSale(context, biz, s.id, text: text));
                  case 'pdf':
                    if (context.mounted) await guard(context, () => PrintService.shareSale(context, biz, s.id, pdf: true, text: text));
                  case 'sms':
                    if (context.mounted && phone != null) {
                      await guard(context, () => Messaging.sms(biz, phone, text), success: T.smsSent.s);
                    }
                  default:
                    await Clipboard.setData(ClipboardData(text: text));
                    if (context.mounted) toast(context, T.copied.s);
                }
              },
              itemBuilder: (_) => [
                PopupMenuItem(value: 'wa', child: _mi(Icons.chat_outlined, T.sendWhatsapp.s)),
                PopupMenuItem(value: 'img', child: _mi(Icons.image_outlined, T.shareInvoice.s)),
                PopupMenuItem(value: 'pdf', child: _mi(Icons.picture_as_pdf_outlined, T.sharePdf.s)),
                if (phone != null) PopupMenuItem(value: 'sms', child: _mi(Icons.sms_outlined, T.sendSms.s)),
                PopupMenuItem(value: 'copy', child: _mi(Icons.copy_rounded, T.copyText.s)),
              ],
              child: IgnorePointer(
                child: OutlinedButton.icon(onPressed: () {}, icon: const Icon(Icons.share_outlined, size: 18), label: Text(T.share.s)),
              ),
            ),
            if (s.status == 'completed' && actor.can(Cap.returns))
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(foregroundColor: C.outRed),
                onPressed: () => showReturnDialog(context, ref, detail),
                icon: const Icon(Icons.assignment_return_outlined, size: 18),
                label: Text(T.returnItems.s),
              ),
          ],
        ),
        Padding(
          padding: EdgeInsets.symmetric(horizontal: context.gutter),
          child: AdaptiveRow(children: [
            Expanded(
              flex: 3,
              child: Panel(
                padding: EdgeInsets.zero,
                child: Column(children: [
                  TableHead([
                    Col(T.items.s, flex: 6),
                    Col(T.qty.s, flex: 2, align: TextAlign.right),
                    Col(T.price.s, flex: 3, align: TextAlign.right),
                    Col(T.total.s, flex: 3, align: TextAlign.right),
                  ]),
                  for (final it in detail.items)
                    TableRowX(
                      cols: const [Col('', flex: 6), Col('', flex: 2, align: TextAlign.right), Col('', flex: 3, align: TextAlign.right), Col('', flex: 3, align: TextAlign.right)],
                      onTap: it.productId == null ? null : () => context.go('/products/${it.productId}'),
                      cells: [
                        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(it.name, style: Txt.strong.copyWith(color: !fullyReturned && it.netQty <= 0 ? C.ink3 : null)),
                          if (it.returnedQty > 0 && !fullyReturned)
                            Text(T.alreadyReturned.f({'n': qty(it.returnedQty)}), style: Txt.tiny.copyWith(color: C.outRed)),
                        ]),
                        Text('${qty(fullyReturned && !steppedReturn ? it.qty : it.netQty)} ${unitLabel(it.unit)}', style: Txt.small),
                        MoneyText(it.price, style: Txt.num.copyWith(fontWeight: FontWeight.w500)),
                        MoneyText(fullyReturned && !steppedReturn ? it.total : it.netTotal),
                      ],
                    ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(18, 14, 18, 18),
                    child: Row(children: [
                      const Spacer(),
                      SizedBox(
                        width: 300,
                        child: Column(children: [
                          if (partReturned) _line(T.returnedItems.s, '−${money(returnedValue)}', color: C.outRed),
                          _line(partReturned ? T.netSale.s : T.subtotal.s, money(s.subtotal)),
                          if (s.discount > 0) _line(T.discount.s, '−${money(s.discount)}'),
                          if (s.vat > 0) _line(T.vat.s, money(s.vat)),
                          const Divider(height: 18),
                          _line(T.total.s, money(s.total), big: true),
                          _line(T.paid.s, money(s.paid)),
                          if (detail.due > 0) _line(T.due.s, money(detail.due), color: C.outRed),
                        ]),
                      ),
                    ]),
                  ),
                ]),
              ),
            ),
            const Gap(16),
            Expanded(
              flex: 2,
              child: Column(children: [
                Panel(
                  title: T.customer.s,
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    detail.contact == null
                        ? Text(T.walkIn.s, style: Txt.body.copyWith(color: C.ink2))
                        : InkWell(
                            onTap: () => context.go('/customers/${detail.contact!.id}'),
                            child: Row(children: [
                              Avatar(detail.contact!.name),
                              const Gap(10),
                              Expanded(child: Cell2(detail.contact!.name, detail.contact!.phone == null ? null : digits(detail.contact!.phone!))),
                              const Icon(Icons.chevron_right_rounded, color: C.ink3),
                            ]),
                          ),
                    const Gap(10),
                    Row(children: [
                      const Icon(Icons.badge_outlined, size: 16, color: C.ink3),
                      const Gap(8),
                      Text('${T.soldBy.s}: ', style: Txt.small),
                      Expanded(child: Text(s.createdBy ?? T.role_owner.s, style: Txt.strong, overflow: TextOverflow.ellipsis)),
                    ]),
                  ]),
                ),
                if (actor.can(Cap.seeCost)) ...[
                  const Gap(16),
                  Panel(
                    title: T.profit.s,
                    child: Column(children: [
                      _line(T.netSales.s, money(s.subtotal - s.discount)),
                      _line(T.cogs.s, '−${money(s.costTotal)}'),
                      const Divider(height: 18),
                      _line(T.grossProfit.s, money(profit), big: true, color: profit >= 0 ? C.inGreen : C.outRed),
                    ]),
                  ),
                ],
                if (s.note != null) ...[
                  const Gap(16),
                  Panel(title: T.note.s, child: Text(s.note!, style: Txt.body)),
                ],
              ]),
            ),
          ]),
        ),
      ]);
    });
  }

  Future<void> _print(BuildContext context, Biz biz, int saleId, String? paper) async {
    if (paper == 'pdf') {
      await guard(context, () => PrintService.saveSalePdf(context, biz, saleId));
      return;
    }
    var direct = false;
    final ok = await guard(context, () async => direct = await PrintService.printSale(context, biz, saleId, paper: paper));
    if (ok && direct && context.mounted) toast(context, T.printed.s);
  }

  static Widget _mi(IconData icon, String label) => Row(children: [
        Icon(icon, size: 18, color: C.ink2),
        const SizedBox(width: 10),
        Text(label),
      ]);

  Widget _line(String k, String v, {bool big = false, Color? color}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(children: [
          Text(k, style: big ? Txt.strong.copyWith(fontSize: 15) : Txt.small),
          const Spacer(),
          Text(v, style: big ? Txt.display(20, color: color ?? C.ink) : Txt.num.copyWith(color: color ?? C.ink, fontSize: 14)),
        ]),
      );
}

/// "Print" prints straight away with the default paper; the arrow picks another size.
class _PrintButton extends StatelessWidget {
  final void Function(String? paper) onPrint;
  const _PrintButton({required this.onPrint});

  @override
  Widget build(BuildContext context) {
    return Row(mainAxisSize: MainAxisSize.min, children: [
      FilledButton.icon(
        style: FilledButton.styleFrom(
            shape: const RoundedRectangleBorder(borderRadius: BorderRadius.horizontal(left: Radius.circular(10)))),
        onPressed: () => onPrint(null),
        icon: const Icon(Icons.print_outlined, size: 18),
        label: Text(T.print.s),
      ),
      const SizedBox(width: 1),
      PopupMenuButton<String>(
        tooltip: T.paperSize.s,
        position: PopupMenuPosition.under,
        onSelected: onPrint,
        itemBuilder: (_) => [
          PopupMenuItem(value: '80', child: Text(T.paper80.s)),
          PopupMenuItem(value: '58', child: Text(T.paper58.s)),
          PopupMenuItem(value: 'a4', child: Text(T.paperA4.s)),
          PopupMenuItem(value: 'pdf', child: Text(T.savePdf.s)),
        ],
        child: IgnorePointer(
          child: FilledButton(
            style: FilledButton.styleFrom(
              minimumSize: const Size(36, 40),
              padding: const EdgeInsets.symmetric(horizontal: 8),
              shape: const RoundedRectangleBorder(borderRadius: BorderRadius.horizontal(right: Radius.circular(10))),
            ),
            onPressed: () {},
            child: const Icon(Icons.arrow_drop_down_rounded, size: 20),
          ),
        ),
      ),
    ]);
  }
}

/// Pick quantities to take back; previews the refund before saving.
Future<void> showReturnDialog(BuildContext context, WidgetRef ref, SaleDetail d) async {
  final biz = ref.read(bizProvider);
  final items = [for (final it in d.items) if (it.netQty > 0) it];
  final ctrls = {for (final it in items) it.id: TextEditingController()};
  final note = TextEditingController();
  int? account = d.sale.accountId;
  String? err;
  await showDialog<void>(
    context: context,
    builder: (ctx) => StatefulBuilder(builder: (ctx, setD) {
      Map<int, double> picked() => {for (final it in items) it.id: parseNum(ctrls[it.id]!.text)};
      final pv = biz.sales.previewReturn(d.sale, d.items, picked());
      Future<void> save() async {
        try {
          await biz.sales.returnItems(d.sale.id, picked(), refundAccountId: account, note: note.text);
          if (ctx.mounted) Navigator.pop(ctx);
          if (context.mounted) toast(context, T.returnDone.s);
        } catch (e) {
          setD(() => err = errorText(e));
        }
      }

      return AppDialog(
        title: T.returnItems.s,
        icon: Icons.assignment_return_outlined,
        tone: Tone.bad,
        width: 560,
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(T.cancel.s)),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: C.outRed),
            onPressed: pv.value > 0 ? save : null,
            child: Text(T.confirm.s),
          ),
        ],
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(T.returnItemsHint.s, style: Txt.small),
          const Gap(10),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: () => setD(() {
                for (final it in items) {
                  ctrls[it.id]!.text = _plain(it.netQty);
                }
                err = null;
              }),
              icon: const Icon(Icons.select_all_rounded, size: 18),
              label: Text(T.returnAll.s),
            ),
          ),
          for (final it in items)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(children: [
                Expanded(
                  child: Cell2(it.name,
                      '${T.soldQty.s} ${qty(it.qty)} ${unitLabel(it.unit)} × ${money(it.price)}${it.returnedQty > 0 ? ' · ${T.alreadyReturned.f({'n': qty(it.returnedQty)})}' : ''}'),
                ),
                const Gap(10),
                SizedBox(
                  width: 120,
                  child: TextField(
                    key: ValueKey('ret-${it.id}'),
                    controller: ctrls[it.id],
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    inputFormatters: [NumberInputFormatter()],
                    textAlign: TextAlign.right,
                    decoration: InputDecoration(isDense: true, hintText: '0', suffixText: '/ ${qty(it.netQty)}'),
                    onChanged: (_) => setD(() => err = null),
                  ),
                ),
              ]),
            ),
          const Divider(height: 22),
          _kv(T.returnValue.s, money(pv.value)),
          if (pv.dueCut > 0) _kv(T.refundToKhata.s, money(pv.dueCut)),
          _kv(T.refundAmount.s, money(pv.refund), strong: true),
          if (pv.refund > 0) ...[
            const Gap(10),
            Text(T.refundFrom.s, style: Txt.label),
            const Gap(6),
            AccountChips(value: account, onChanged: (v) => setD(() => account = v)),
          ],
          const Gap(10),
          TextField(controller: note, decoration: InputDecoration(labelText: T.note.s, isDense: true)),
          if (err != null) ...[
            const Gap(8),
            Text(err!, style: Txt.small.copyWith(color: C.outRed)),
          ],
        ]),
      );
    }),
  );
  for (final c in ctrls.values) {
    c.dispose();
  }
  note.dispose();
}

/// A quantity as plain digits for a text box (no grouping or Bangla digits).
String _plain(double v) => v == v.roundToDouble() ? v.toInt().toString() : v.toString();

Widget _kv(String k, String v, {bool strong = false}) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(children: [
        Expanded(child: Text(k, style: strong ? Txt.strong : Txt.small)),
        Text(v, style: strong ? Txt.display(18) : Txt.num.copyWith(fontSize: 14)),
      ]),
    );
