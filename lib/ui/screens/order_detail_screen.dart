import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/format.dart';
import '../../core/i18n.dart';
import '../../core/theme.dart';
import '../../core/util.dart';
import '../../couriers/registry.dart';
import '../../data/biz.dart';
import '../../services/messaging.dart';
import '../../services/templates.dart';
import '../../services/print_service.dart';
import '../../state/app_state.dart';
import '../widgets/common.dart';
import '../widgets/delivery_record.dart';
import 'sale_detail_screen.dart';

class OrderDetailScreen extends ConsumerWidget {
  final int id;
  const OrderDetailScreen({super.key, required this.id});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final d = ref.watch(saleDetailProvider(id));
    final biz = ref.watch(bizProvider);
    final settings = ref.watch(settingsProvider).value ?? const {};
    final cfg = CourierConfig(settings.json(K.courierConfig));

    return AsyncView(d, builder: (detail) {
      if (detail == null) return EmptyState(icon: Icons.inbox_outlined, text: T.e_not_found.s);
      final s = detail.sale;
      final ship = detail.shipment;
      final open = openOrderStatuses.contains(s.status);
      final cod = detail.due;

      final actions = <Widget>[
        StatusPill(s.status),
        _printMenu(context, biz, s.id),
        if (s.shipPhone != null)
          OutlinedButton.icon(
            onPressed: () => Messaging.whatsapp(
              s.shipPhone!,
              orderMessage(
                ref.read(settingsProvider).value ?? const {},
                switch (s.status) {
                  'booked' => MsgKind.shipped,
                  'delivered' || 'partial' => MsgKind.delivered,
                  _ => MsgKind.confirmed,
                },
                detail,
              ),
            ),
            icon: const Icon(Icons.chat_outlined, size: 18),
            label: Text(T.whatsapp.s),
          ),
        if (s.status == 'pending')
          FilledButton.icon(
            onPressed: () => guard(context, () async {
              await biz.orders.confirm(s.id);
              unawaited(autoNotifyOrder(biz, s.id, MsgKind.confirmed));
            }),
            icon: const Icon(Icons.check_rounded, size: 18),
            label: Text(T.confirmOrder.s),
          ),
        if (s.status == 'pending' || s.status == 'confirmed')
          FilledButton.icon(
            style: FilledButton.styleFrom(backgroundColor: C.marigold, foregroundColor: C.brandDeep),
            onPressed: () => _book(context, ref, s.id, cfg),
            icon: const Icon(Icons.local_shipping_outlined, size: 18),
            label: Text(T.bookCourier.s),
          ),
        if (open)
          PopupMenuButton<String>(
            tooltip: T.more.s,
            onSelected: (v) {
              switch (v) {
                case 'delivered':
                  _deliver(context, ref, detail, cfg);
                case 'returned':
                  _returned(context, ref, detail, cfg);
                case 'cancel':
                  _cancel(context, ref, detail);
              }
            },
            itemBuilder: (_) => [
              PopupMenuItem(value: 'delivered', child: _mi(Icons.task_alt_rounded, T.markDelivered.s, C.inGreen)),
              // Returns and cancellations move money back: managers and the owner only.
              if (s.status == 'booked' && ref.watch(actorProvider).can(Cap.returns))
                PopupMenuItem(value: 'returned', child: _mi(Icons.keyboard_return_rounded, T.markReturned.s, C.warn)),
              if (ref.watch(actorProvider).can(Cap.returns))
                PopupMenuItem(value: 'cancel', child: _mi(Icons.cancel_outlined, T.cancelOrder.s, C.outRed)),
            ],
            child: IgnorePointer(child: OutlinedButton.icon(onPressed: () {}, icon: const Icon(Icons.more_horiz_rounded, size: 18), label: Text(T.more.s))),
          ),
      ];

      return ListView(padding: const EdgeInsets.only(bottom: 28), children: [
        PageHeader(
          leading: IconButton(onPressed: () => context.go('/orders'), icon: const Icon(Icons.arrow_back_rounded)),
          title: s.invoiceNo,
          subtitle: dateLong(s.date),
          actions: actions,
        ),
        Padding(
          padding: EdgeInsets.symmetric(horizontal: context.gutter),
          child: AdaptiveRow(children: [
            Expanded(
              flex: 3,
              child: Column(children: [
                _StatusTrack(status: s.status),
                const Gap(16),
                Panel(
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
                        cells: [
                          Text(it.name, style: Txt.strong),
                          Text('${qty(it.qty)} ${unitLabel(it.unit)}', style: Txt.small),
                          MoneyText(it.price, style: Txt.num.copyWith(fontWeight: FontWeight.w500)),
                          MoneyText(it.total),
                        ],
                      ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(18, 14, 18, 18),
                      child: Row(children: [
                        const Spacer(),
                        SizedBox(
                          width: 300,
                          child: Column(children: [
                            _line(T.subtotal.s, money(s.subtotal)),
                            if (s.discount > 0) _line(T.discount.s, '−${money(s.discount)}'),
                            _line(T.deliveryCharge.s, money(s.deliveryCharge)),
                            const Divider(height: 18),
                            _line(T.total.s, money(s.total), big: true),
                            if (s.paid > 0) _line(open ? T.advance.s : T.paid.s, money(s.paid)),
                            if (open) _line(T.cod.s, money(cod), big: true, color: C.brand),
                          ]),
                        ),
                      ]),
                    ),
                  ]),
                ),
              ]),
            ),
            const Gap(16),
            Expanded(
              flex: 2,
              child: Column(children: [
                Panel(
                  title: T.deliveryAddress.s,
                  trailing: IconButton(
                    tooltip: T.copyAddress.s,
                    onPressed: () {
                      Clipboard.setData(ClipboardData(
                          text: [s.shipName, s.shipPhone, s.shipAddress, s.shipArea, s.shipCity].whereType<String>().join('\n')));
                      toast(context, T.copied.s);
                    },
                    icon: const Icon(Icons.copy_rounded, size: 18),
                  ),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(s.shipName ?? '', style: Txt.strong.copyWith(fontSize: 16)),
                    if (s.shipPhone != null) Text(digits(s.shipPhone!), style: Txt.body),
                    const Gap(6),
                    Text(joinAddress([s.shipAddress, s.shipArea, s.shipCity]), style: Txt.small),
                    if (s.note != null) ...[const Gap(8), Pill('${T.note.s}: ${s.note}', tone: Tone.accent)],
                    if (s.shipPhone != null) ...[const Gap(12), DeliveryRecord(phone: s.shipPhone!)],
                  ]),
                ),
                const Gap(16),
                if (ship != null)
                  Panel(
                    title: courierNames[ship.courier] ?? ship.courier,
                    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      if (ship.consignmentId != null) _kv(T.consignment.s, ship.consignmentId!, copy: true, context: context),
                      if (ship.trackingCode != null && ship.trackingCode != ship.consignmentId)
                        _kv(T.tracking.s, ship.trackingCode!, copy: true, context: context),
                      if (ship.courierStatus != null) _kv(T.courierStatus.s, ship.courierStatus!),
                      _kv(T.cod.s, money(ship.codAmount)),
                      if (ship.fee > 0) _kv(T.courierCharge.s, money(ship.fee)),
                      if (ship.updatedAt != null) _kv(T.time.s, friendlyDate(ship.updatedAt!)),
                      if (ship.trackingUrl != null) ...[
                        const Gap(8),
                        OutlinedButton.icon(
                          onPressed: () => Messaging.openUrl(ship.trackingUrl!),
                          icon: const Icon(Icons.open_in_new_rounded, size: 17),
                          label: Text(T.tracking.s),
                        ),
                      ],
                    ]),
                  ),
              ]),
            ),
          ]),
        ),
      ]);
    });
  }

  Widget _printMenu(BuildContext context, Biz biz, int saleId) => PopupMenuButton<String>(
        tooltip: T.print.s,
        position: PopupMenuPosition.under,
        onSelected: (v) => v == 'pdf'
            ? guard(context, () => PrintService.saveSalePdf(context, biz, saleId))
            : guard(context, () => PrintService.printSale(context, biz, saleId, paper: v)),
        itemBuilder: (_) => [
          PopupMenuItem(value: '80', child: Text(T.paper80.s)),
          PopupMenuItem(value: '58', child: Text(T.paper58.s)),
          PopupMenuItem(value: 'a4', child: Text(T.paperA4.s)),
          PopupMenuItem(value: 'pdf', child: Text(T.savePdf.s)),
        ],
        child: IgnorePointer(
          child: OutlinedButton.icon(onPressed: () {}, icon: const Icon(Icons.print_outlined, size: 18), label: Text(T.print.s)),
        ),
      );

  Widget _mi(IconData i, String t, Color c) => Row(children: [Icon(i, size: 18, color: c), const Gap(10), Text(t)]);

  Widget _line(String k, String v, {bool big = false, Color? color}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(children: [
          Text(k, style: big ? Txt.strong.copyWith(fontSize: 15) : Txt.small),
          const Spacer(),
          Text(v, style: big ? Txt.display(20, color: color ?? C.ink) : Txt.num.copyWith(fontSize: 14)),
        ]),
      );

  Widget _kv(String k, String v, {bool copy = false, BuildContext? context}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(children: [
          SizedBox(width: 130, child: Text(k, style: Txt.small)),
          Expanded(child: SelectableText(v, style: Txt.strong)),
          if (copy && context != null)
            IconButton(
              iconSize: 16,
              visualDensity: VisualDensity.compact,
              onPressed: () {
                Clipboard.setData(ClipboardData(text: v));
                toast(context, T.copied.s);
              },
              icon: const Icon(Icons.copy_rounded),
            ),
        ]),
      );

  Future<void> _book(BuildContext context, WidgetRef ref, int saleId, CourierConfig cfg) async {
    final configured = cfg.configured;
    var courier = configured.contains(cfg.defaultCourier) ? cfg.defaultCourier : (configured.isEmpty ? 'manual' : configured.first);
    final tracking = TextEditingController();
    final fee = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AppDialog(
          title: T.bookCourier.s,
          icon: Icons.local_shipping_outlined,
          tone: Tone.accent,
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(T.cancel.s)),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(T.bookCourier.s)),
          ],
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (configured.isEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Text(T.configureCourier.s, style: Txt.small.copyWith(color: C.warn)),
              ),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final c in [...configured, 'manual'])
                ChoiceChip(
                  label: Text(c == 'manual' ? T.ownRider.s : courierNames[c]!),
                  selected: courier == c,
                  onSelected: (_) => setD(() => courier = c),
                ),
            ]),
            if (courier == 'manual') ...[
              const Gap(14),
              TextIn(controller: tracking, label: '${T.tracking.s} (${T.optional.s})'),
              const Gap(12),
              NumField(controller: fee, label: T.courierCharge.s, prefix: '৳ '),
            ],
          ]),
        ),
      ),
    );
    if (ok == true && context.mounted) {
      final biz = ref.read(bizProvider);
      await guard(context, () async {
        if (courier == 'manual') {
          await biz.orders.bookManual(saleId, trackingCode: tracking.text.trim().isEmpty ? null : tracking.text.trim(), fee: parseNum(fee.text));
        } else {
          final s = await biz.orders.book(saleId, courier);
          if (context.mounted) toast(context, T.courierBooked.f({'c': courierNames[courier], 'id': s.consignmentId ?? ''}));
        }
        unawaited(autoNotifyOrder(biz, saleId, MsgKind.shipped));
      });
    }
    tracking.dispose();
    fee.dispose();
  }

  Future<void> _deliver(BuildContext context, WidgetRef ref, SaleDetail d, CourierConfig cfg) async {
    final collected = TextEditingController(text: _p(d.due));
    final ship = d.shipment;
    final fee = TextEditingController(text: _p(ship != null && ship.fee > 0 ? ship.fee : (ship == null ? 0 : cfg.deliveryFee)));
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AppDialog(
        title: T.markDelivered.s,
        icon: Icons.task_alt_rounded,
        tone: Tone.good,
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(T.cancel.s)),
          FilledButton(style: FilledButton.styleFrom(backgroundColor: C.inGreen), onPressed: () => Navigator.pop(ctx, true), child: Text(T.confirm.s)),
        ],
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          NumField(controller: collected, label: T.collected.s, prefix: '৳ ', autofocus: true,
              helper: isBangla ? 'কম হলে আংশিক ডেলিভারি হিসেবে ধরা হবে' : 'Less than COD = partly delivered'),
          const Gap(12),
          NumField(controller: fee, label: T.courierCharge.s, prefix: '৳ '),
          const Gap(10),
          Text(ship != null && ship.courier != 'manual' ? T.courierPayoutHint.s : '', style: Txt.tiny),
        ]),
      ),
    );
    if (ok == true && context.mounted) {
      final biz = ref.read(bizProvider);
      final ok = await guard(context, () => biz.orders.markDelivered(d.sale.id, collected: parseNum(collected.text), fee: parseNum(fee.text)),
          success: T.saved.s);
      if (ok) unawaited(autoNotifyOrder(biz, d.sale.id, MsgKind.delivered));
    }
    collected.dispose();
    fee.dispose();
  }

  Future<void> _returned(BuildContext context, WidgetRef ref, SaleDetail d, CourierConfig cfg) async {
    final fee = TextEditingController(text: _p(cfg.returnFee));
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AppDialog(
        title: T.markReturned.s,
        icon: Icons.keyboard_return_rounded,
        tone: Tone.warn,
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(T.cancel.s)),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(T.confirm.s)),
        ],
        child: NumField(controller: fee, label: T.returnCharge.s, prefix: '৳ ', autofocus: true),
      ),
    );
    if (ok == true && context.mounted) {
      await guard(context, () => ref.read(bizProvider).orders.markReturned(d.sale.id, fee: parseNum(fee.text)), success: T.saved.s);
    }
    fee.dispose();
  }

  Future<void> _cancel(BuildContext context, WidgetRef ref, SaleDetail d) async {
    var refund = d.sale.paid > 0;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AppDialog(
          title: T.cancelOrder.s,
          icon: Icons.cancel_outlined,
          tone: Tone.bad,
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(T.back.s)),
            FilledButton(style: FilledButton.styleFrom(backgroundColor: C.outRed), onPressed: () => Navigator.pop(ctx, true), child: Text(T.cancelOrder.s)),
          ],
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(T.areYouSure.s, style: Txt.body),
            if (d.sale.paid > 0)
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: refund,
                onChanged: (v) => setD(() => refund = v ?? false),
                title: Text('${T.refundAdvance.s} (${money(d.sale.paid)})'),
              ),
          ]),
        ),
      ),
    );
    if (ok == true && context.mounted) {
      await guard(context, () => ref.read(bizProvider).orders.cancel(d.sale.id, refundAdvance: refund), success: T.saved.s);
    }
  }

  static String _p(double v) => v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(2);
}

/// pending → confirmed → with courier → delivered, drawn as a progress rail.
class _StatusTrack extends StatelessWidget {
  final String status;
  const _StatusTrack({required this.status});

  @override
  Widget build(BuildContext context) {
    const steps = ['pending', 'confirmed', 'booked', 'delivered'];
    final failed = status == 'returned' || status == 'cancelled';
    final reached = switch (status) {
      'pending' => 0,
      'confirmed' => 1,
      'booked' => 2,
      'delivered' || 'partial' => 3,
      'returned' => 2,
      _ => 0,
    };
    return Panel(
      child: Row(children: [
        for (var i = 0; i < steps.length; i++) ...[
          if (i > 0)
            Expanded(
              child: Container(
                height: 3,
                margin: const EdgeInsets.symmetric(horizontal: 6),
                decoration: BoxDecoration(
                  color: i <= reached ? (failed ? C.outRed.withValues(alpha: 0.5) : C.brandMid) : C.line,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
          Column(mainAxisSize: MainAxisSize.min, children: [
            Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: i < reached || (i == reached && !failed) ? C.brand : (i == reached && failed ? C.outRed : C.paper2),
              ),
              child: Icon(
                i == reached && failed
                    ? Icons.close_rounded
                    : (i <= reached ? Icons.check_rounded : Icons.circle_outlined),
                size: 15,
                color: i <= reached ? Colors.white : C.ink3,
              ),
            ),
            const Gap(6),
            Text(
              i == 3 && status == 'partial'
                  ? T.st_partial.s
                  : (i == reached && failed ? tKey('st', status) : tKey('st', steps[i])),
              style: Txt.tiny.copyWith(color: i <= reached ? C.ink : C.ink3, fontWeight: i == reached ? FontWeight.w700 : FontWeight.w400),
            ),
          ]),
        ],
      ]),
    );
  }
}
