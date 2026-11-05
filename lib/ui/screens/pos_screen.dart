import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/format.dart';
import '../../core/i18n.dart';
import '../../core/theme.dart';
import '../../core/util.dart';
import '../../data/biz.dart';
import '../../services/print_service.dart';
import '../../state/app_state.dart';
import '../../services/messaging.dart';
import '../../services/templates.dart';
import '../widgets/common.dart';
import '../widgets/scanner.dart';
import '../widgets/pickers.dart';

final _posProducts = StreamProvider.autoDispose.family<List<Product>, (String, int?)>(
    (ref, a) => ref.watch(bizProvider).products.watchProducts(query: a.$1, categoryId: a.$2));
final _categories = StreamProvider.autoDispose((ref) => ref.watch(bizProvider).products.watchCategories());

class _Line {
  final int uid;
  CartLine line;
  final double? stock; // null when stock isn't tracked
  final TextEditingController qtyC;
  final TextEditingController priceC;
  _Line(this.uid, this.line, this.stock)
      : qtyC = TextEditingController(text: qtyText(line.qty)),
        priceC = TextEditingController(text: _plain(line.price));

  void dispose() {
    qtyC.dispose();
    priceC.dispose();
  }
}

String qtyText(double v) => v == v.roundToDouble() ? v.toInt().toString() : v.toString();
String _plain(double v) => v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(2);

class PosScreen extends ConsumerStatefulWidget {
  const PosScreen({super.key});
  @override
  ConsumerState<PosScreen> createState() => _PosScreenState();
}

class _PosScreenState extends ConsumerState<PosScreen> {
  final search = TextEditingController();
  final searchFocus = FocusNode();
  final received = TextEditingController();
  final discountC = TextEditingController();
  final vatC = TextEditingController();
  final noteC = TextEditingController();
  final lines = <_Line>[];
  int _uid = 0;
  int? categoryId;
  Contact? customer;
  double customerBalance = 0;
  int? accountId;
  bool discountPct = false;
  bool wholesale = false;
  bool saving = false;
  String query = '';

  /// Phones: the cart is a separate full-screen page.
  bool showCart = false;

  @override
  void initState() {
    super.initState();
    Future.microtask(_loadDefaults);
  }

  Future<void> _loadDefaults() async {
    final biz = ref.read(bizProvider);
    final s = await biz.settings.all();
    final def = int.tryParse(s[K.defaultAccount] ?? '');
    final acc = def ?? await biz.cash.defaultCashAccount();
    if (!mounted) return;
    setState(() {
      accountId = acc;
      final vat = s.num(K.vatPercent);
      vatC.text = vat == 0 ? '' : _plain(vat);
    });
  }

  @override
  void dispose() {
    for (final l in lines) {
      l.dispose();
    }
    search.dispose();
    searchFocus.dispose();
    received.dispose();
    discountC.dispose();
    vatC.dispose();
    noteC.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------ cart ops

  void _add(Product p) {
    final price = wholesale && p.wholesalePrice > 0 ? p.wholesalePrice : p.salePrice;
    final existing = lines.where((l) => l.line.productId == p.id).firstOrNull;
    setState(() {
      if (existing != null) {
        _setQty(existing, existing.line.qty + 1);
      } else {
        lines.add(_Line(
          ++_uid,
          CartLine(productId: p.id, name: p.name, qty: 1, price: price, unit: p.unit, trackStock: p.trackStock),
          p.trackStock ? p.stock : null,
        ));
      }
    });
    final inCart = lines.firstWhere((l) => l.line.productId == p.id).line.qty;
    if (p.trackStock && inCart > p.stock) {
      toast(context, p.stock <= 0 ? '${p.name}: ${T.outOfStock.s}' : T.stockWarning.f({'n': qty(p.stock)}), error: true);
    }
  }

  void _setQty(_Line l, double q) {
    l.line = l.line.copyWith(qty: q);
    l.qtyC.text = qtyText(q);
  }

  void _remove(_Line l) {
    setState(() => lines.remove(l));
    l.dispose();
  }

  void _clear() {
    setState(() {
      for (final l in lines) {
        l.dispose();
      }
      lines.clear();
      customer = null;
      customerBalance = 0;
      received.clear();
      discountC.clear();
      noteC.clear();
      showCart = false;
    });
    _refocus();
  }

  /// Keep the barcode field focused on desktops (scanner input); on phones
  /// that would keep popping up the on-screen keyboard.
  void _refocus() {
    if (!isMobilePlatform) searchFocus.requestFocus();
  }

  Future<void> _submitSearch(String q) async {
    final biz = ref.read(bizProvider);
    final term = q.trim();
    if (term.isEmpty) return;
    final exact = await biz.products.byCode(term);
    if (exact != null) {
      _add(exact);
      search.clear();
      setState(() => query = '');
      _refocus();
      return;
    }
    final list = await biz.products.search(term, limit: 2);
    if (!mounted) return;
    if (list.isNotEmpty) {
      _add(list.first);
      search.clear();
      setState(() => query = '');
    } else {
      await _customItem(name: term);
    }
    _refocus();
  }

  Future<void> _customItem({String name = ''}) async {
    final nameC = TextEditingController(text: name);
    final priceC = TextEditingController();
    final qtyC = TextEditingController(text: '1');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AppDialog(
        title: T.customItem.s,
        icon: Icons.edit_note_rounded,
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(T.cancel.s)),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(T.add.s)),
        ],
        child: Column(children: [
          Text(T.customItemHint.s, style: Txt.small),
          const Gap(14),
          TextIn(controller: nameC, label: T.name.s, autofocus: name.isEmpty),
          const Gap(12),
          Row(children: [
            Expanded(
                child: NumField(
                    controller: priceC,
                    label: T.price.s,
                    prefix: '৳ ',
                    autofocus: name.isNotEmpty,
                    onSubmitted: (_) => Navigator.pop(ctx, true))),
            const Gap(12),
            SizedBox(width: 110, child: NumField(controller: qtyC, label: T.qty.s)),
          ]),
        ]),
      ),
    );
    if (ok == true && nameC.text.trim().isNotEmpty) {
      final q = parseNum(qtyC.text, 1);
      setState(() {
        lines.add(_Line(++_uid,
            CartLine(name: nameC.text.trim(), qty: q <= 0 ? 1 : q, price: parseNum(priceC.text), trackStock: false), null));
        search.clear();
        query = '';
      });
    }
    nameC.dispose();
    priceC.dispose();
    qtyC.dispose();
  }

  Future<void> _pickCustomer() async {
    final c = await pickContact(context, 'customer');
    if (c == null) return;
    final bal = await ref.read(bizProvider).contacts.balanceOf(c.id);
    setState(() {
      customer = c;
      customerBalance = bal;
    });
  }

  // ------------------------------------------------------------ totals

  SaleTotals get totals {
    final cart = lines.map((l) => l.line).toList();
    final sub = computeTotals(cart).subtotal;
    final d = parseNum(discountC.text);
    final disc = discountPct ? r2(sub * d / 100) : d;
    return computeTotals(cart, discount: disc, vatPercent: parseNum(vatC.text));
  }

  double get paidAmount {
    final t = totals.total;
    if (received.text.trim().isEmpty) return t;
    return parseNum(received.text);
  }

  Future<void> _complete() async {
    if (saving) return;
    if (lines.isEmpty) {
      toast(context, T.e_cart_empty.s, error: true);
      return;
    }
    final t = totals;
    final paid = paidAmount;
    final due = r2(t.total - paid);
    if (due > 0 && customer == null) {
      toast(context, T.e_due_needs_customer.s, error: true);
      _pickCustomer();
      return;
    }
    setState(() => saving = true);
    final biz = ref.read(bizProvider);
    try {
      final id = await biz.sales.createSale(
        lines: lines.map((l) => l.line).toList(),
        discount: t.discount,
        vatPercent: parseNum(vatC.text),
        contactId: customer?.id,
        paid: paid.clamp(0, t.total).toDouble(),
        accountId: paid > 0 ? accountId : null,
        note: noteC.text,
      );
      final change = paid > t.total ? r2(paid - t.total) : 0.0;
      final settings = await biz.settings.all();
      _clear();
      if (!mounted) return;
      if (settings.flag(K.autoPrint)) {
        guard(context, () => PrintService.printSale(context, biz, id));
      }
      await showDialog(context: context, builder: (_) => _DoneDialog(saleId: id, total: t.total, change: change, due: due > 0 ? due : 0));
      _refocus();
    } catch (e) {
      if (mounted) toast(context, errorText(e), error: true);
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  // ------------------------------------------------------------ UI

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.f9): _complete,
        const SingleActivator(LogicalKeyboardKey.enter, control: true): _complete,
        const SingleActivator(LogicalKeyboardKey.f2): () => searchFocus.requestFocus(),
        const SingleActivator(LogicalKeyboardKey.f12): () => _pickCustomer(),
        const SingleActivator(LogicalKeyboardKey.escape): () {
          search.clear();
          setState(() => query = '');
          searchFocus.requestFocus();
        },
      },
      child: context.isCompact
          ? (showCart ? _cartPage() : Column(children: [Expanded(child: _productSide()), _cartBar()]))
          : Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Expanded(child: _productSide()),
              Container(width: 1, color: C.line),
              SizedBox(width: MediaQuery.sizeOf(context).width < 1200 ? 360 : 430, child: _cartSide()),
            ]),
    );
  }

  Widget _productSide() {
    final cats = ref.watch(_categories).value ?? const <ProductCategory>[];
    final products = ref.watch(_posProducts((query, categoryId)));
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: EdgeInsets.fromLTRB(context.gutter, context.isPhone ? 12 : 20, context.gutter, 12),
        child: Row(children: [
          Expanded(child: Text(T.newSale.s, style: Txt.display(24), maxLines: 1, overflow: TextOverflow.ellipsis)),
          FilterChip(
            label: Text(T.useWholesale.s),
            selected: wholesale,
            avatar: Icon(Icons.inventory_outlined, size: 16, color: wholesale ? C.brand : C.ink3),
            onSelected: (v) => setState(() => wholesale = v),
          ),
          const Gap(8),
          if (MediaQuery.sizeOf(context).width < 1200)
            IconButton.outlined(
              tooltip: T.customItem.s,
              onPressed: () => _customItem(),
              icon: const Icon(Icons.edit_note_rounded, size: 20),
            )
          else
            OutlinedButton.icon(
              onPressed: () => _customItem(),
              icon: const Icon(Icons.edit_note_rounded, size: 19),
              label: Text(T.customItem.s),
            ),
        ]),
      ),
      Padding(
        padding: EdgeInsets.symmetric(horizontal: context.gutter),
        child: TextField(
          controller: search,
          focusNode: searchFocus,
          autofocus: !isMobilePlatform,
          style: const TextStyle(fontSize: 16),
          onChanged: (v) => setState(() => query = v),
          onSubmitted: (v) {
            _submitSearch(v);
            _refocus();
          },
          decoration: InputDecoration(
            hintText: T.scanOrSearch.s,
            prefixIcon: const Icon(Icons.qr_code_scanner_rounded),
            suffixIcon: isMobilePlatform
                ? ScanButton(onCode: _submitSearch)
                : Padding(
                    padding: const EdgeInsets.all(12),
                    child: Row(mainAxisSize: MainAxisSize.min, children: const [KeyCap('Enter')]),
                  ),
            contentPadding: const EdgeInsets.symmetric(vertical: 16),
          ),
        ),
      ),
      if (cats.isNotEmpty)
        SizedBox(
          height: 52,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: EdgeInsets.fromLTRB(context.gutter, 10, context.gutter, 6),
            children: [
              ChoiceChip(label: Text(T.all.s), selected: categoryId == null, onSelected: (_) => setState(() => categoryId = null)),
              for (final c in cats) ...[
                const Gap(6),
                ChoiceChip(label: Text(c.name), selected: categoryId == c.id, onSelected: (_) => setState(() => categoryId = c.id)),
              ],
            ],
          ),
        ),
      Expanded(
        child: AsyncView(products, builder: (list) {
          if (list.isEmpty) {
            return EmptyState(
              icon: Icons.search_off_rounded,
              text: query.isEmpty ? T.noProducts.s : T.noProductFound.s,
              action: query.isEmpty
                  ? FilledButton.icon(
                      onPressed: () => context.go('/products'),
                      icon: const Icon(Icons.add, size: 18),
                      label: Text(T.addProduct.s))
                  : null,
            );
          }
          return GridView.builder(
            padding: EdgeInsets.fromLTRB(context.gutter, 8, context.gutter, 24),
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 196,
              mainAxisExtent: 128,
              crossAxisSpacing: 10,
              mainAxisSpacing: 10,
            ),
            itemCount: list.length,
            itemBuilder: (_, i) => _ProductCard(
              product: list[i],
              wholesale: wholesale,
              inCart: lines.where((l) => l.line.productId == list[i].id).fold<double>(0, (s, l) => s + l.line.qty),
              onTap: () {
                _add(list[i]);
                _refocus();
              },
            ),
          );
        }),
      ),
    ]);
  }

  Widget _customerCard() {
    return Padding(
    padding: const EdgeInsets.fromLTRB(18, 18, 18, 10),
    child: Material(
      color: customer == null ? C.paper : C.brandSoft,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: _pickCustomer,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(children: [
            Avatar(customer?.name ?? '?', size: 34, tone: customer == null ? Tone.neutral : Tone.brand),
            const Gap(10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(customer?.name ?? T.walkIn.s, style: Txt.strong, maxLines: 1, overflow: TextOverflow.ellipsis),
                Text(
                  customer == null
                      ? (isMobilePlatform ? T.selectCustomer.s : '${T.selectCustomer.s} · F12')
                      : customerBalance.abs() < 0.01
                          ? (customer!.phone == null ? T.settled.s : digits(customer!.phone!))
                          : '${customerBalance > 0 ? T.willGet.s : T.willGive.s} ${money(customerBalance.abs())}',
                  style: Txt.tiny.copyWith(color: customerBalance > 0.01 ? C.inGreen : C.ink3),
                ),
              ]),
            ),
            if (customer != null)
              IconButton(
                tooltip: T.remove.s,
                onPressed: () => setState(() {
                  customer = null;
                  customerBalance = 0;
                }),
                icon: const Icon(Icons.close_rounded, size: 18),
              )
            else
              const Icon(Icons.chevron_right_rounded, color: C.ink3),
          ]),
        ),
      ),
    ),
  );
  }

  Widget _cartHeader() {
    return Padding(
    padding: const EdgeInsets.fromLTRB(18, 4, 12, 6),
    child: Row(children: [
      Text(T.cart.s, style: Txt.strong.copyWith(fontSize: 15)),
      const Gap(8),
      if (lines.isNotEmpty) Pill(itemsText(lines.length), tone: Tone.brand),
      const Spacer(),
      if (lines.isNotEmpty)
        TextButton.icon(
          onPressed: _clear,
          style: TextButton.styleFrom(foregroundColor: C.outRed),
          icon: const Icon(Icons.delete_sweep_outlined, size: 18),
          label: Text(T.clearCart.s),
        ),
    ]),
  );
  }

  Widget _totalsPanel() {
    final t = totals;
    final paid = paidAmount;
    final change = paid > t.total ? r2(paid - t.total) : 0.0;
    final due = paid < t.total ? r2(t.total - paid) : 0.0;
    return Container(
    decoration: const BoxDecoration(color: C.paper, border: Border(top: BorderSide(color: C.line))),
    padding: const EdgeInsets.fromLTRB(18, 12, 18, 16),
    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        Expanded(
          child: TextField(
            controller: discountC,
            inputFormatters: [NumberInputFormatter()],
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              labelText: T.discount.s,
              suffixIcon: GestureDetector(
                onTap: () => setState(() => discountPct = !discountPct),
                child: MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: Container(
                    margin: const EdgeInsets.all(7),
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    alignment: Alignment.center,
                    width: 36,
                    decoration: BoxDecoration(color: C.brandSoft, borderRadius: BorderRadius.circular(6)),
                    child: Text(discountPct ? '%' : '৳', style: const TextStyle(fontWeight: FontWeight.w700, color: C.brand)),
                  ),
                ),
              ),
            ),
          ),
        ),
        const Gap(10),
        SizedBox(width: 92, child: NumField(controller: vatC, label: T.vatPct.s, onChanged: (_) => setState(() {}))),
      ]),
      const Gap(10),
      _totalRow(T.subtotal.s, money(t.subtotal)),
      if (t.discount > 0) _totalRow(T.discount.s, '−${money(t.discount)}', color: C.outRed),
      if (t.vat > 0) _totalRow(T.vat.s, money(t.vat)),
      const Gap(4),
      Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
        Text(T.total.s, style: Txt.strong.copyWith(fontSize: 16)),
        const Spacer(),
        Text(money(t.total), style: Txt.display(30, color: C.brand)),
      ]),
      const Gap(12),
      AccountChips(value: accountId, onChanged: (v) => setState(() => accountId = v)),
      const Gap(10),
      Row(children: [
        Expanded(
          child: NumField(
            controller: received,
            label: '${T.received.s} (${money(t.total)})',
            prefix: '৳ ',
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) => _complete(),
          ),
        ),
        const Gap(8),
        for (final quick in _quickNotes(t.total))
          Padding(
            padding: const EdgeInsets.only(left: 4),
            child: OutlinedButton(
              style: OutlinedButton.styleFrom(minimumSize: const Size(0, 44), padding: const EdgeInsets.symmetric(horizontal: 10)),
              onPressed: () => setState(() => received.text = _plain(quick)),
              child: Text(number(quick)),
            ),
          ),
      ]),
      const Gap(8),
      if (change > 0)
        _payInfo(T.changeDue.s, money(change), Tone.info)
      else if (due > 0)
        _payInfo(customer == null ? T.e_due_needs_customer.s : T.dueToKhata.s, money(due), Tone.bad),
      const Gap(10),
      SizedBox(
        height: 54,
        child: FilledButton(
          onPressed: lines.isEmpty || saving ? null : _complete,
          style: FilledButton.styleFrom(
            backgroundColor: C.brand,
            textStyle: const TextStyle(fontFamily: kBody, fontSize: 17, fontWeight: FontWeight.w700),
          ),
          child: saving
              ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.4, color: Colors.white))
              : Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  const Icon(Icons.check_circle_outline_rounded),
                  const Gap(10),
                  Text(T.completeSale.s),
                  const Gap(10),
                  const KeyCap('F9', dark: true),
                ]),
        ),
      ),
    ]),
  );
  }

  /// Phone: sticky bar under the products — item count, total, open cart.
  Widget _cartBar() {
    if (lines.isEmpty) return const SizedBox.shrink();
    final t = totals;
    return Material(
      color: C.brand,
      child: InkWell(
        onTap: () => setState(() => showCart = true),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
          child: Row(children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(color: C.marigold, borderRadius: BorderRadius.circular(8)),
              child: Text(number(lines.length),
                  style: const TextStyle(fontFamily: kBody, fontWeight: FontWeight.w700, color: C.brandDeep)),
            ),
            const Gap(10),
            Expanded(
              child: Text(T.cart.s,
                  style: const TextStyle(fontFamily: kBody, fontSize: 15, fontWeight: FontWeight.w600, color: Colors.white)),
            ),
            Text(money(t.total), style: Txt.display(20, color: Colors.white)),
            const Icon(Icons.chevron_right_rounded, color: Colors.white),
          ]),
        ),
      ),
    );
  }

  /// Desktop: fixed right-hand panel with a scrolling cart in the middle.
  Widget _cartSide() {
    return Container(
      color: C.card,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _customerCard(),
        _cartHeader(),
        const Divider(),
        Expanded(
          child: lines.isEmpty
              ? EmptyState(icon: Icons.shopping_basket_outlined, text: T.emptyCart.s)
              : ListView.separated(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  itemCount: lines.length,
                  separatorBuilder: (_, _) => const Divider(indent: 18, endIndent: 18),
                  itemBuilder: (_, i) => _cartTile(lines[i]),
                ),
        ),
        _totalsPanel(),
      ]),
    );
  }

  /// Phone: the whole cart and payment as one scrolling page.
  Widget _cartPage() {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) setState(() => showCart = false);
      },
      child: Container(
        color: C.card,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 6, 8, 0),
            child: Row(children: [
              IconButton(onPressed: () => setState(() => showCart = false), icon: const Icon(Icons.arrow_back_rounded)),
              Expanded(child: Text(T.cart.s, style: Txt.display(20))),
            ]),
          ),
          Expanded(
            child: ListView(children: [
              _customerCard(),
              _cartHeader(),
              const Divider(),
              if (lines.isEmpty)
                Padding(padding: const EdgeInsets.all(24), child: Text(T.emptyCart.s, textAlign: TextAlign.center, style: Txt.small))
              else
                for (final l in lines) ...[_cartTile(l), const Divider(indent: 18, endIndent: 18)],
              _totalsPanel(),
            ]),
          ),
        ]),
      ),
    );
  }

  List<double> _quickNotes(double total) {
    if (total <= 0) return const [];
    final out = <double>{};
    for (final note in [100.0, 500.0, 1000.0]) {
      final rounded = (total / note).ceil() * note;
      if (rounded > total) out.add(rounded);
      if (out.length == 2) break;
    }
    return out.toList();
  }

  Widget _totalRow(String k, String v, {Color? color}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 1.5),
        child: Row(children: [
          Text(k, style: Txt.small),
          const Spacer(),
          Text(v, style: Txt.num.copyWith(fontSize: 13.5, color: color ?? C.ink2)),
        ]),
      );

  Widget _payInfo(String label, String value, Tone tone) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(color: tone.bg, borderRadius: BorderRadius.circular(9)),
        child: Row(children: [
          Expanded(child: Text(label, style: Txt.small.copyWith(color: tone.fg, fontWeight: FontWeight.w600))),
          Text(value, style: Txt.strong.copyWith(color: tone.fg, fontSize: 16)),
        ]),
      );

  Widget _cartTile(_Line l) {
    final over = l.stock != null && l.line.qty > l.stock!;
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 8, 8, 8),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(l.line.name, style: Txt.strong, maxLines: 2, overflow: TextOverflow.ellipsis),
            const Gap(4),
            Row(children: [
              SizedBox(
                width: 86,
                height: 32,
                child: TextField(
                  controller: l.priceC,
                  inputFormatters: [NumberInputFormatter()],
                  style: Txt.num.copyWith(fontSize: 13),
                  decoration: const InputDecoration(prefixText: '৳ ', contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 6)),
                  onChanged: (v) => setState(() => l.line = l.line.copyWith(price: parseNum(v))),
                ),
              ),
              if (l.line.unit != null)
                Flexible(
                  child: Padding(
                    padding: const EdgeInsets.only(left: 6),
                    child: Text('/ ${unitLabel(l.line.unit)}', style: Txt.tiny, maxLines: 1, overflow: TextOverflow.ellipsis),
                  ),
                ),
              if (over) ...[
                const Gap(6),
                Tooltip(
                  message: l.stock! <= 0 ? T.outOfStock.s : T.stockWarning.f({'n': qty(l.stock!)}),
                  child: const Icon(Icons.warning_amber_rounded, size: 16, color: C.warn),
                ),
              ],
            ]),
          ]),
        ),
        _Stepper(
          controller: l.qtyC,
          onMinus: () => setState(() {
            if (l.line.qty <= 1) {
              _remove(l);
            } else {
              _setQty(l, l.line.qty - 1);
            }
          }),
          onPlus: () => setState(() => _setQty(l, l.line.qty + 1)),
          onChanged: (v) => setState(() => l.line = l.line.copyWith(qty: parseNum(v, 0))),
        ),
        SizedBox(
          width: 86,
          child: Text(money(l.line.total), textAlign: TextAlign.right, style: Txt.num),
        ),
        IconButton(
          tooltip: T.remove.s,
          onPressed: () => _remove(l),
          icon: const Icon(Icons.close_rounded, size: 17, color: C.ink3),
        ),
      ]),
    );
  }
}

class _Stepper extends StatelessWidget {
  final TextEditingController controller;
  final VoidCallback onMinus;
  final VoidCallback onPlus;
  final ValueChanged<String> onChanged;
  const _Stepper({required this.controller, required this.onMinus, required this.onPlus, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    Widget btn(IconData i, VoidCallback f) => InkWell(
          onTap: f,
          borderRadius: BorderRadius.circular(8),
          child: SizedBox(width: 28, height: 32, child: Icon(i, size: 16, color: C.brand)),
        );
    return Container(
      height: 34,
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(9), border: Border.all(color: C.line)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        btn(Icons.remove_rounded, onMinus),
        SizedBox(
          width: 42,
          child: TextField(
            controller: controller,
            textAlign: TextAlign.center,
            inputFormatters: [NumberInputFormatter()],
            style: Txt.num.copyWith(fontSize: 14),
            decoration: const InputDecoration(
              filled: false,
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
              contentPadding: EdgeInsets.symmetric(vertical: 8),
            ),
            onChanged: onChanged,
          ),
        ),
        btn(Icons.add_rounded, onPlus),
      ]),
    );
  }
}

class _ProductCard extends StatefulWidget {
  final Product product;
  final bool wholesale;
  final double inCart;
  final VoidCallback onTap;
  const _ProductCard({required this.product, required this.wholesale, required this.inCart, required this.onTap});
  @override
  State<_ProductCard> createState() => _ProductCardState();
}

class _ProductCardState extends State<_ProductCard> {
  bool hover = false;
  @override
  Widget build(BuildContext context) {
    final p = widget.product;
    final price = widget.wholesale && p.wholesalePrice > 0 ? p.wholesalePrice : p.salePrice;
    final out = p.trackStock && p.stock <= 0;
    final low = p.trackStock && !out && p.stock <= p.lowStock;
    final hasImage = p.imagePath != null && File(p.imagePath!).existsSync();
    return MouseRegion(
      onEnter: (_) => setState(() => hover = true),
      onExit: (_) => setState(() => hover = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 110),
          transform: Matrix4.translationValues(0, hover ? -2 : 0, 0),
          decoration: BoxDecoration(
            color: C.card,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: widget.inCart > 0 ? C.brand : (hover ? C.brandMid.withValues(alpha: 0.5) : C.line), width: widget.inCart > 0 ? 1.6 : 1),
            boxShadow: hover ? [BoxShadow(color: C.ink.withValues(alpha: 0.06), blurRadius: 12, offset: const Offset(0, 4))] : null,
          ),
          padding: const EdgeInsets.all(10),
          child: Stack(children: [
            Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                if (hasImage)
                  ClipRRect(
                    borderRadius: BorderRadius.circular(7),
                    child: Image.file(File(p.imagePath!), width: 34, height: 34, fit: BoxFit.cover, cacheWidth: 96),
                  )
                else
                  Avatar(p.name, size: 34, tone: out ? Tone.neutral : Tone.brand),
                const Gap(8),
                Expanded(
                  child: Text(p.name,
                      maxLines: 3, overflow: TextOverflow.ellipsis, style: Txt.strong.copyWith(fontSize: 13.5, height: 1.2)),
                ),
              ]),
              const Spacer(),
              Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                // Big prices shrink instead of wrapping onto a second line.
                Expanded(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Text(money(price), maxLines: 1, style: Txt.display(17, color: out ? C.ink3 : C.ink)),
                  ),
                ),
                if (p.trackStock)
                  Text(out ? T.outOfStock.s : qty(p.stock),
                      style: Txt.tiny.copyWith(color: out ? C.outRed : (low ? C.warn : C.ink3), fontWeight: FontWeight.w600)),
              ]),
            ]),
            if (widget.inCart > 0)
              Positioned(
                left: 18,
                top: 22,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                  decoration: BoxDecoration(color: C.brand, borderRadius: BorderRadius.circular(8)),
                  child: Text('×${qty(widget.inCart)}',
                      style: const TextStyle(fontFamily: kBody, color: Colors.white, fontSize: 11, fontWeight: FontWeight.w700)),
                ),
              ),
          ]),
        ),
      ),
    );
  }
}

class _DoneDialog extends ConsumerWidget {
  final int saleId;
  final double total;
  final double change;
  final double due;
  const _DoneDialog({required this.saleId, required this.total, required this.change, required this.due});

  /// Receipt as text to the customer's WhatsApp (or any chat when walk-in).
  Future<void> _share(BuildContext context, WidgetRef ref) async {
    final biz = ref.read(bizProvider);
    final d = await biz.sales.detail(saleId);
    if (d == null) return;
    final text = invoiceMessage(ref.read(settingsProvider).value ?? const {}, d);
    await Messaging.whatsapp(d.contact?.phone ?? '', text);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final biz = ref.watch(bizProvider);
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyP): () => guard(context, () => PrintService.printSale(context, biz, saleId)),
      },
      child: Dialog(
        child: Container(
          width: 400,
          padding: const EdgeInsets.fromLTRB(28, 28, 28, 22),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Container(
              width: 64,
              height: 64,
              decoration: const BoxDecoration(color: C.inSoft, shape: BoxShape.circle),
              child: const Icon(Icons.check_rounded, size: 38, color: C.inGreen),
            ),
            const Gap(14),
            Text(T.saleDone.s, style: Txt.display(22)),
            const Gap(4),
            Text(money(total), style: Txt.display(34, color: C.brand)),
            if (change > 0) ...[
              const Gap(10),
              Pill('${T.changeDue.s}: ${money(change)}', tone: Tone.info),
            ],
            if (due > 0) ...[
              const Gap(10),
              Pill('${T.dueToKhata.s}: ${money(due)}', tone: Tone.bad),
            ],
            const Gap(22),
            FieldRow(minFieldWidth: 130, children: [OutlinedButton.icon(
                  onPressed: () => guard(context, () => PrintService.printSale(context, biz, saleId)),
                  icon: const Icon(Icons.print_outlined, size: 18),
                  label: Row(mainAxisSize: MainAxisSize.min, children: [Text(T.printReceipt.s), const Gap(6), const KeyCap('P')]),
                ), OutlinedButton.icon(
                  onPressed: () => _share(context, ref),
                  icon: const Icon(Icons.chat_outlined, size: 18),
                  label: Text(T.whatsapp.s),
                ), FilledButton(
                  autofocus: true,
                  onPressed: () => Navigator.pop(context),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [Text(T.newSale.s), const Gap(6), const KeyCap('Enter', dark: true)]),
                )]),
            const Gap(6),
            TextButton(
              onPressed: () {
                Navigator.pop(context);
                context.go('/sales/$saleId');
              },
              child: Text(T.details.s),
            ),
          ]),
        ),
      ),
    );
  }
}
