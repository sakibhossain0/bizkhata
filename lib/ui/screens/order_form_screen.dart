import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/bd.dart';
import '../../core/format.dart';
import '../../core/i18n.dart';
import '../../core/theme.dart';
import '../../core/util.dart';
import '../../data/biz.dart';
import '../../state/app_state.dart';
import '../widgets/common.dart';
import '../widgets/delivery_record.dart';
import '../widgets/pickers.dart';

class _OLine {
  final int? productId;
  final String name;
  final String? unit;
  final double? stock;
  final TextEditingController qty;
  final TextEditingController price;
  _OLine({this.productId, required this.name, this.unit, this.stock, required double p})
      : qty = TextEditingController(text: '1'),
        price = TextEditingController(text: p == p.roundToDouble() ? p.toInt().toString() : p.toString());

  CartLine get line => CartLine(productId: productId, name: name, qty: parseNum(qty.text, 0), price: parseNum(price.text), unit: unit);
  void dispose() {
    qty.dispose();
    price.dispose();
  }
}

class OrderFormScreen extends ConsumerStatefulWidget {
  const OrderFormScreen({super.key});
  @override
  ConsumerState<OrderFormScreen> createState() => _OrderFormScreenState();
}

class _OrderFormScreenState extends ConsumerState<OrderFormScreen> {
  final phone = TextEditingController();
  final name = TextEditingController();
  final address = TextEditingController();
  final area = TextEditingController();
  final city = TextEditingController(text: 'Dhaka');
  final note = TextEditingController();
  final delivery = TextEditingController(text: '60');
  final discount = TextEditingController();
  final advance = TextEditingController();
  final lines = <_OLine>[];
  int? advanceAccount;
  String lookedUp = '';

  @override
  void initState() {
    super.initState();
    Future.microtask(() async {
      final biz = ref.read(bizProvider);
      final cfg = await biz.orders.courierConfig();
      final acc = (await biz.cash.accounts()).where((a) => a.kind == 'mobile').firstOrNull?.id ?? await biz.cash.defaultCashAccount();
      if (!mounted) return;
      setState(() {
        advanceAccount = acc;
        delivery.text = _plain(cfg.json['insideDhaka'] as num? ?? 60);
      });
    });
  }

  String _plain(num v) => v == v.roundToDouble() ? v.toInt().toString() : v.toString();

  @override
  void dispose() {
    for (final c in [phone, name, address, area, city, note, delivery, discount, advance]) {
      c.dispose();
    }
    for (final l in lines) {
      l.dispose();
    }
    super.dispose();
  }

  Future<void> _lookup(String v) async {
    final p = normalizePhone(v);
    if (!isValidBdMobile(p) || p == lookedUp) {
      setState(() {});
      return;
    }
    lookedUp = p;
    final c = await ref.read(bizProvider).contacts.byPhone('customer', p);
    if (!mounted) return;
    setState(() {
      if (c != null) {
        if (name.text.trim().isEmpty) name.text = c.name;
        if (address.text.trim().isEmpty && c.address != null) address.text = c.address!;
      }
    });
  }

  void _add(Product p) {
    final existing = lines.where((l) => l.productId == p.id).firstOrNull;
    setState(() {
      if (existing != null) {
        existing.qty.text = qty(parseNum(existing.qty.text) + 1);
      } else {
        lines.add(_OLine(productId: p.id, name: p.name, unit: p.unit, stock: p.trackStock ? p.stock : null, p: p.salePrice));
      }
    });
  }

  SaleTotals get totals => computeTotals(lines.map((l) => l.line).toList(),
      discount: parseNum(discount.text), deliveryCharge: parseNum(delivery.text));

  Future<void> _save({bool book = false}) async {
    final biz = ref.read(bizProvider);
    var id = 0;
    await guard(context, () async {
      id = await biz.orders.create(
        name: name.text,
        phone: phone.text,
        address: address.text,
        area: area.text,
        city: city.text,
        lines: lines.map((l) => l.line).toList(),
        discount: parseNum(discount.text),
        deliveryCharge: parseNum(delivery.text),
        advance: parseNum(advance.text),
        advanceAccountId: parseNum(advance.text) > 0 ? advanceAccount : null,
        note: note.text,
      );
      if (book) {
        final cfg = await biz.orders.courierConfig();
        await biz.orders.confirm(id);
        await biz.orders.book(id, cfg.defaultCourier);
      }
    }, success: T.orderSaved.s);
    // Booking can fail after the order itself was saved; open it either way.
    if (id > 0 && mounted) context.go('/orders/$id');
  }

  @override
  Widget build(BuildContext context) {
    final t = totals;
    final adv = parseNum(advance.text).clamp(0, t.total);
    final cod = t.total - adv;
    final validPhone = isValidBdMobile(phone.text);
    return ListView(padding: const EdgeInsets.only(bottom: 28), children: [
      PageHeader(
        leading: IconButton(onPressed: () => context.go('/orders'), icon: const Icon(Icons.arrow_back_rounded)),
        title: T.newOrder.s,
        actions: [
          OutlinedButton.icon(
            onPressed: () => _save(book: true),
            icon: const Icon(Icons.local_shipping_outlined, size: 18),
            label: Text('${T.save.s} + ${T.bookCourier.s}'),
          ),
          BusyButton(label: T.save.s, icon: Icons.check_rounded, onPressed: () => _save()),
        ],
      ),
      Padding(
        padding: EdgeInsets.symmetric(horizontal: context.gutter),
        child: AdaptiveRow(children: [
          Expanded(
            flex: 4,
            child: Panel(
              title: T.customer.s,
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                TextIn(
                  controller: phone,
                  label: T.phone.s,
                  icon: Icons.phone_outlined,
                  keyboard: TextInputType.phone,
                  autofocus: true,
                  onChanged: _lookup,
                ),
                if (validPhone) ...[const Gap(10), DeliveryRecord(phone: phone.text)],
                const Gap(12),
                TextIn(controller: name, label: T.customerName.s, icon: Icons.person_outline_rounded),
                const Gap(12),
                TextIn(controller: address, label: T.deliveryAddress.s, icon: Icons.home_outlined, maxLines: 2),
                const Gap(12),
                FieldRow(children: [TextIn(controller: area, label: T.area.s), Autocomplete<String>(
                      initialValue: TextEditingValue(text: city.text),
                      optionsBuilder: (v) => bdDistricts.where((d) => d.toLowerCase().startsWith(v.text.toLowerCase())),
                      onSelected: (v) => setState(() {
                        city.text = v;
                        delivery.text = isInsideDhaka(v) ? '60' : '120';
                      }),
                      fieldViewBuilder: (ctx, ctrl, focus, _) {
                        ctrl.addListener(() => city.text = ctrl.text);
                        return TextField(controller: ctrl, focusNode: focus, decoration: InputDecoration(labelText: T.city.s));
                      },
                    )]),
                const Gap(12),
                TextIn(controller: note, label: T.noteOptional.s, icon: Icons.sticky_note_2_outlined),
              ]),
            ),
          ),
          const Gap(16),
          Expanded(
            flex: 5,
            child: Panel(
              title: T.items.s,
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                ProductSearchField(
                  onPick: _add,
                  onCustom: (text) => setState(() => lines.add(_OLine(name: text, p: 0))),
                ),
                const Gap(10),
                if (lines.isEmpty)
                  Padding(padding: const EdgeInsets.all(20), child: Center(child: Text(T.e_cart_empty.s, style: Txt.small)))
                else
                  for (final l in lines)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 5),
                      child: _lineEditor(l),
                    ),
                const Divider(height: 24),
                NumField(controller: delivery, label: T.deliveryCharge.s, prefix: '৳ ', onChanged: (_) => setState(() {})),
                const Gap(8),
                Wrap(spacing: 6, runSpacing: 6, children: [
                  for (final v in [60, 120])
                    ChoiceChip(
                      label: Text(v == 60 ? (isBangla ? 'ঢাকার ভিতরে ৳৬০' : 'Inside Dhaka ৳60') : (isBangla ? 'ঢাকার বাইরে ৳১২০' : 'Outside Dhaka ৳120')),
                      selected: parseNum(delivery.text) == v,
                      onSelected: (_) => setState(() => delivery.text = '$v'),
                    ),
                ]),
                const Gap(12),
                FieldRow(children: [NumField(controller: discount, label: T.discount.s, prefix: '৳ ', onChanged: (_) => setState(() {})), NumField(controller: advance, label: T.advance.s, prefix: '৳ ', onChanged: (_) => setState(() {}))]),
                if (parseNum(advance.text) > 0) ...[
                  const Gap(10),
                  AccountChips(value: advanceAccount, onChanged: (v) => setState(() => advanceAccount = v)),
                ],
                const Gap(16),
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(color: C.paper, borderRadius: BorderRadius.circular(12)),
                  child: Column(children: [
                    _row(T.subtotal.s, money(t.subtotal)),
                    if (t.discount > 0) _row(T.discount.s, '−${money(t.discount)}'),
                    _row(T.deliveryCharge.s, money(t.deliveryCharge)),
                    _row(T.total.s, money(t.total), strong: true),
                    if (adv > 0) _row(T.advance.s, '−${money(adv)}'),
                    const Divider(height: 18),
                    Row(children: [
                      Text(T.cod.s, style: Txt.strong.copyWith(fontSize: 15)),
                      const Spacer(),
                      Text(money(cod), style: Txt.display(26, color: C.brand)),
                    ]),
                  ]),
                ),
              ]),
            ),
          ),
        ]),
      ),
    ]);
  }

  /// One product line: everything in a row on wide screens, two rows on phones.
  Widget _lineEditor(_OLine l) {
    final remove = IconButton(
      onPressed: () => setState(() {
        lines.remove(l);
        l.dispose();
      }),
      icon: const Icon(Icons.close_rounded, size: 18, color: C.ink3),
    );
    final title = Cell2(l.name, l.stock == null ? null : T.inStockN.f({'n': qty(l.stock!)}));
    final qtyField = NumField(controller: l.qty, label: T.qty.s, onChanged: (_) => setState(() {}));
    final priceField = NumField(controller: l.price, label: T.price.s, prefix: '৳ ', onChanged: (_) => setState(() {}));
    final total = Text(money(l.line.total), textAlign: TextAlign.right, style: Txt.num);
    return LayoutBuilder(builder: (context, box) {
      if (box.maxWidth < 520) {
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [Expanded(child: title), total, remove]),
          const Gap(6),
          Row(children: [Expanded(child: qtyField), const Gap(8), Expanded(flex: 2, child: priceField)]),
        ]);
      }
      return Row(children: [
        Expanded(child: title),
        SizedBox(width: 80, child: qtyField),
        const Gap(8),
        SizedBox(width: 110, child: priceField),
        SizedBox(width: 92, child: total),
        remove,
      ]);
    });
  }

  Widget _row(String k, String v, {bool strong = false}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(children: [
          Text(k, style: strong ? Txt.strong : Txt.small),
          const Spacer(),
          Text(v, style: Txt.num.copyWith(fontWeight: strong ? FontWeight.w700 : FontWeight.w500)),
        ]),
      );
}
