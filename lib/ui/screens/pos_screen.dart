import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
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
  final deliveryC = TextEditingController();
  final vatC = TextEditingController();
  final noteC = TextEditingController();
  final nameC = TextEditingController();
  final phoneC = TextEditingController();
  final nameFocus = FocusNode();
  final phoneFocus = FocusNode();
  final lines = <_Line>[];
  int _uid = 0;
  int? categoryId;

  /// The saved customer this sale goes to: picked from the list, or found from
  /// the typed phone (or the exact name while no phone is typed).
  Contact? customer;
  double customerBalance = 0;

  /// Linked only because the typed name matched, so editing the name unlinks.
  bool _linkedByName = false;

  /// The name we filled in from a phone match; it goes again if the number changes.
  String? _autoName;

  /// Bumped on every change, so a lookup that finishes late is ignored.
  int _lookupSeq = 0;

  /// The typed name belongs to more than one saved customer, so it links none.
  bool _nameAmbiguous = false;

  /// The one scrolling cart page (phones, and short desktop panels), so a
  /// refused sale can bring the customer fields back into view.
  final _cartScroll = ScrollController();

  /// "Due" chosen instead of an account: nothing is paid now, all goes to khata.
  bool dueMode = false;
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
    deliveryC.dispose();
    vatC.dispose();
    noteC.dispose();
    nameC.dispose();
    phoneC.dispose();
    nameFocus.dispose();
    phoneFocus.dispose();
    _cartScroll.dispose();
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
      _unlink();
      nameC.clear();
      phoneC.clear();
      received.clear();
      discountC.clear();
      deliveryC.clear();
      noteC.clear();
      dueMode = false;
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

  // ------------------------------------------------------------ customer

  Future<void> _pickCustomer() async {
    final c = await pickContact(context, 'customer');
    if (c == null || !mounted) return;
    final bal = await ref.read(bizProvider).contacts.balanceOf(c.id);
    if (!mounted) return;
    setState(() {
      _unlink();
      nameC.text = c.name;
      phoneC.text = c.phone ?? '';
      customer = c;
      customerBalance = bal;
    });
  }

  /// Back to a walk-in sale (the x on the customer line).
  void _removeCustomer() {
    setState(() {
      _unlink();
      nameC.clear();
      phoneC.clear();
    });
  }

  /// Drops the linked customer; call inside setState.
  void _unlink() {
    customer = null;
    customerBalance = 0;
    _linkedByName = false;
    _autoName = null;
    _nameAmbiguous = false;
    _lookupSeq++;
  }

  bool get _hasCustomer => customer != null || nameC.text.trim().isNotEmpty || phoneC.text.trim().isNotEmpty;

  /// A number typed for a linked customer who has none saved: it is saved on
  /// them with the sale.
  bool get _addingPhone =>
      customer != null && normalizePhone(customer!.phone).isEmpty && normalizePhone(phoneC.text).isNotEmpty;

  /// A whole mobile number (01 and nine more digits), or a landline's 8 to 11.
  /// A number starting with 1 is a mobile typed without its 0 (landlines in
  /// Bangladesh never start with 1), so it must be a whole mobile number too.
  static bool _phoneComplete(String p) =>
      p.startsWith('01') || p.startsWith('1') ? isValidBdMobile(p) : p.length >= 8 && p.length <= 11;

  static bool _sameName(String a, String b) => a.trim().toLowerCase() == b.trim().toLowerCase();

  void _onPhoneChanged(String v) {
    final c = customer;
    final phone = normalizePhone(v);
    final saved = normalizePhone(c?.phone);
    setState(() {
      // A customer with no saved number keeps the link: the number typed is
      // taken as theirs, unless _lookup finds it belongs to someone else.
      if (c == null || saved.isEmpty) return;
      if (phone != saved) {
        // The number decides who this is: a different number is someone else.
        final auto = _autoName;
        _unlink();
        if (auto != null && nameC.text == auto) nameC.clear();
      } else {
        _linkedByName = false; // now held by the number, so name edits keep it
      }
    });
    if (customer == null || normalizePhone(customer!.phone).isEmpty) _lookup();
  }

  void _onNameChanged(String v) {
    final c = customer;
    setState(() {
      if (c != null && _linkedByName && !_sameName(v, c.name)) _unlink();
    });
    if (customer == null) _lookup();
  }

  /// Finds the saved customer the typed details point to: by phone once the
  /// number looks complete, or by the exact name while no phone is typed. A
  /// linked customer with no saved number is only replaced by the customer
  /// the typed number belongs to.
  Future<void> _lookup() async {
    final seq = ++_lookupSeq;
    final linked = customer;
    final phone = normalizePhone(phoneC.text);
    final name = nameC.text.trim();
    final contacts = ref.read(bizProvider).contacts;
    Contact? found;
    var ambiguous = false;
    if (phone.isNotEmpty) {
      if (_phoneComplete(phone)) found = await contacts.byPhone('customer', phone);
    } else if (linked == null && name.isNotEmpty) {
      final match = await contacts.customerByName(name);
      found = match.contact;
      ambiguous = match.ambiguous;
    }
    final other = found != null && found.id != linked?.id ? found : null;
    final bal = other == null ? 0.0 : await contacts.balanceOf(other.id);
    // Something was typed or picked meanwhile: this answer is for old input.
    if (!mounted || seq != _lookupSeq || customer?.id != linked?.id) return;
    setState(() {
      _nameAmbiguous = ambiguous;
      if (other == null) return;
      // Switching away from a linked customer: their name goes with them.
      if (linked != null && _sameName(nameC.text, linked.name)) nameC.clear();
      customer = other;
      customerBalance = bal;
      _linkedByName = phone.isEmpty;
      if (phone.isNotEmpty && nameC.text.trim().isEmpty) {
        nameC.text = other.name;
        _autoName = other.name;
      }
    });
  }

  /// Puts the cursor in a customer field, opening the phone cart page first.
  void _focusField(FocusNode node) {
    if (context.isCompact && !showCart) setState(() => showCart = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // On a long cart the fields may be scrolled away, and then they aren't
      // built: back to the top. A field that isn't built yet takes the focus
      // as soon as it is.
      if (_cartScroll.hasClients) _cartScroll.jumpTo(0);
      node.requestFocus();
    });
  }

  // ------------------------------------------------------------ totals

  SaleTotals get totals {
    final cart = lines.map((l) => l.line).toList();
    final sub = computeTotals(cart).subtotal;
    final d = parseNum(discountC.text);
    final disc = discountPct ? r2(sub * d / 100) : d;
    return computeTotals(cart, discount: disc, vatPercent: parseNum(vatC.text), deliveryCharge: parseNum(deliveryC.text));
  }

  /// Paid now: nothing in Due mode, the whole total while Received is empty.
  double get paidAmount {
    if (dueMode) return 0;
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
    final name = nameC.text.trim();
    final phone = phoneC.text.trim();
    final linked = customer;
    final addPhone = _addingPhone;
    if (due > 0 && !_hasCustomer) {
      toast(context, T.e_due_needs_customer.s, error: true);
      _focusField(nameFocus);
      return;
    }
    // A half-typed number would be saved: on a new customer, or on the linked
    // one when they have none yet.
    if (phone.isNotEmpty && normalizePhone(linked?.phone).isEmpty && !_phoneComplete(normalizePhone(phone))) {
      toast(context, T.e_phone_invalid.s, error: true);
      _focusField(phoneFocus);
      return;
    }
    setState(() => saving = true);
    final biz = ref.read(bizProvider);
    try {
      final int? contactId;
      if (linked != null) {
        if (addPhone) await biz.contacts.setPhone(linked.id, phone);
        contactId = linked.id;
      } else {
        contactId = name.isNotEmpty || phone.isNotEmpty ? await biz.contacts.customerFor(name: name, phone: phone) : null;
      }
      final id = await biz.sales.createSale(
        lines: lines.map((l) => l.line).toList(),
        discount: t.discount,
        vatPercent: parseNum(vatC.text),
        deliveryCharge: t.deliveryCharge,
        contactId: contactId,
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
      if (mounted) {
        toast(context, errorText(e), error: true);
        // Several customers share the typed name: let the cashier pick which.
        if (e is BizException && e.message == 'name_ambiguous') _pickCustomer();
      }
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

  /// Name and phone, both optional, plus the saved-customers list (F12).
  /// Kept to one row: the desktop cart panel is narrow and short.
  Widget _customerFields() {
    final c = customer;
    Widget? note;
    if (c != null) {
      final balance = customerBalance.abs() < 0.01
          ? T.settled.s
          : '${customerBalance > 0 ? T.willGet.s : T.willGive.s} ${money(customerBalance.abs())}';
      note = Row(children: [
        const Icon(Icons.person_rounded, size: 15, color: C.brand),
        const Gap(5),
        Expanded(
          child: Text.rich(
            TextSpan(children: [
              if (_addingPhone)
                TextSpan(text: T.posAddPhone.f({'x': c.name}), style: const TextStyle(color: C.ink, fontWeight: FontWeight.w600))
              else ...[
                TextSpan(text: c.name, style: const TextStyle(color: C.ink, fontWeight: FontWeight.w600)),
                // Tells apart customers who share a name.
                if (c.phone != null) TextSpan(text: '  ·  ${digits(c.phone!)}'),
              ],
              TextSpan(text: '  ·  $balance', style: TextStyle(color: customerBalance > 0.01 ? C.inGreen : C.ink3)),
            ]),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Txt.tiny,
          ),
        ),
        IconButton(
          key: const ValueKey('pos-customer-remove'),
          tooltip: T.remove.s,
          onPressed: _removeCustomer,
          icon: const Icon(Icons.close_rounded, size: 15),
          // Small on desktops, where every pixel of height counts; finger-sized on phones.
          style: IconButton.styleFrom(
            minimumSize: isMobilePlatform ? const Size(40, 32) : const Size(26, 20),
            padding: EdgeInsets.zero,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
        ),
      ]);
    } else if (_nameAmbiguous && phoneC.text.trim().isEmpty) {
      note = Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Icon(Icons.people_alt_outlined, size: 15, color: C.warn),
        const Gap(5),
        Expanded(
          child: Text(T.posNameAmbiguous.s,
              maxLines: 2, overflow: TextOverflow.ellipsis, style: Txt.tiny.copyWith(color: C.warn)),
        ),
      ]);
    } else if (_hasCustomer) {
      note = Row(children: [
        const Icon(Icons.person_add_alt_1_outlined, size: 15, color: C.ink3),
        const Gap(5),
        Expanded(child: Text(T.posNewCustomer.s, maxLines: 1, overflow: TextOverflow.ellipsis, style: Txt.tiny)),
      ]);
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 10, 8, 4),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Expanded(
            flex: 5,
            child: TextField(
              key: const ValueKey('pos-customer-name'),
              controller: nameC,
              focusNode: nameFocus,
              textCapitalization: TextCapitalization.words,
              textInputAction: TextInputAction.next,
              onChanged: _onNameChanged,
              onSubmitted: (_) => phoneFocus.requestFocus(),
              decoration: InputDecoration(labelText: T.customerName.s, hintText: T.walkIn.s),
            ),
          ),
          const Gap(8),
          Expanded(
            flex: 4,
            child: TextField(
              key: const ValueKey('pos-customer-phone'),
              controller: phoneC,
              focusNode: phoneFocus,
              keyboardType: TextInputType.phone,
              inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9০-৯+\- ]'))],
              onChanged: _onPhoneChanged,
              onSubmitted: (_) => _refocus(),
              decoration: InputDecoration(labelText: T.phone.s),
            ),
          ),
          IconButton(
            tooltip: isMobilePlatform ? T.posSavedCustomers.s : '${T.posSavedCustomers.s} · F12',
            onPressed: _pickCustomer,
            icon: const Icon(Icons.contacts_outlined, size: 21),
          ),
        ]),
        if (note != null) Padding(padding: const EdgeInsets.fromLTRB(2, 3, 10, 0), child: note),
      ]),
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
      // Discount, delivery and VAT share one row to save height on short screens.
      Row(children: [
        Expanded(
          flex: 5,
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
                    alignment: Alignment.center,
                    width: 30,
                    decoration: BoxDecoration(color: C.brandSoft, borderRadius: BorderRadius.circular(6)),
                    child: Text(discountPct ? '%' : '৳', style: const TextStyle(fontWeight: FontWeight.w700, color: C.brand)),
                  ),
                ),
              ),
            ),
          ),
        ),
        const Gap(8),
        Expanded(
          flex: 4,
          child: NumField(
            key: const ValueKey('pos-delivery'),
            controller: deliveryC,
            label: T.posDelivery.s,
            prefix: '৳ ',
            onChanged: (_) => setState(() {}),
          ),
        ),
        const Gap(8),
        // 76 is the narrowest that still shows the whole "VAT %" label.
        SizedBox(width: 76, child: NumField(controller: vatC, label: T.vatPct.s, onChanged: (_) => setState(() {}))),
      ]),
      const Gap(10),
      _totalRow(T.subtotal.s, money(t.subtotal)),
      if (t.discount > 0) _totalRow(T.discount.s, '−${money(t.discount)}', color: C.outRed),
      if (t.vat > 0) _totalRow(T.vat.s, money(t.vat)),
      if (t.deliveryCharge > 0) _totalRow(T.deliveryCharge.s, money(t.deliveryCharge)),
      const Gap(4),
      Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
        Text(T.total.s, style: Txt.strong.copyWith(fontSize: 16)),
        const Spacer(),
        Text(money(t.total), style: Txt.display(30, color: C.brand)),
      ]),
      const Gap(12),
      Theme(
        // Mouse-sized chips on desktops, where the panel is short; finger-sized on touch screens.
        data: isMobilePlatform
            ? Theme.of(context)
            : Theme.of(context)
                .copyWith(visualDensity: VisualDensity.compact, materialTapTargetSize: MaterialTapTargetSize.shrinkWrap),
        child: AccountChips(
          // In Due mode no account looks chosen; picking one leaves Due mode.
          value: dueMode ? null : accountId,
          onChanged: (v) => setState(() {
            accountId = v;
            dueMode = false;
          }),
          trailing: [
            ChoiceChip(
              key: const ValueKey('pos-due'),
              label: Text(T.due.s),
              avatar: Icon(Icons.menu_book_outlined, size: 16, color: dueMode ? C.outRed : C.ink3),
              selected: dueMode,
              selectedColor: C.outSoft,
              onSelected: (_) => setState(() => dueMode = true),
            ),
          ],
        ),
      ),
      // Due mode: nothing is received now, the whole total goes to khata.
      if (!dueMode) ...[
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
      ],
      const Gap(8),
      if (change > 0)
        _payInfo(T.changeDue.s, money(change), Tone.info)
      else if (due > 0)
        _payInfo(_hasCustomer ? T.dueToKhata.s : T.e_due_needs_customer.s, money(due), Tone.bad),
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

  /// Desktop: fixed right-hand panel with a scrolling cart in the middle. On a
  /// short screen that would squeeze the cart to nothing, the cart keeps a
  /// usable height and the whole panel scrolls by what is missing (see [_CartPanel]).
  Widget _cartSide() {
    return Container(
      color: C.card,
      child: LayoutBuilder(
        builder: (_, box) => SingleChildScrollView(
          controller: _cartScroll,
          child: _CartPanel(
            height: box.maxHeight,
            top: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              _customerFields(),
              _cartHeader(),
              const Divider(),
            ]),
            list: lines.isEmpty
                ? EmptyState(icon: Icons.shopping_basket_outlined, text: T.emptyCart.s)
                : ListView.separated(
                    key: const ValueKey('pos-cart-list'),
                    // The panel sets the height: the room between, but never under about a line and a half.
                    shrinkWrap: true,
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    itemCount: lines.length,
                    separatorBuilder: (_, _) => const Divider(indent: 18, endIndent: 18),
                    itemBuilder: (_, i) => _cartTile(lines[i]),
                  ),
            bottom: _totalsPanel(),
          ),
        ),
      ),
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
            child: ListView(key: const ValueKey('pos-cart-page'), controller: _cartScroll, children: [
              _customerFields(),
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
      key: ValueKey('pos-line-${l.uid}'),
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

/// The desktop cart panel's layout: [top] and [bottom] keep their full
/// height and [list] gets the room left between them, but never less than
/// [minList]. With less room than that the panel grows past [height] by the
/// difference, and the scroll view around it scrolls that little. (Giving the
/// list its whole length would push the total and Complete further down with
/// every line in the cart.)
class _CartPanel extends MultiChildRenderObjectWidget {
  /// The height the panel has on screen.
  final double height;
  _CartPanel({required this.height, required Widget top, required Widget list, required Widget bottom})
      : super(children: [top, list, bottom]);

  /// About a cart line and a half.
  static const minList = 110.0;

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderCartPanel(height);

  @override
  void updateRenderObject(BuildContext context, _RenderCartPanel renderObject) => renderObject.height = height;
}

class _CartPanelSlot extends ContainerBoxParentData<RenderBox> {}

class _RenderCartPanel extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _CartPanelSlot>,
        RenderBoxContainerDefaultsMixin<RenderBox, _CartPanelSlot> {
  _RenderCartPanel(this._height);

  double _height;
  set height(double value) {
    if (value == _height) return;
    _height = value;
    markNeedsLayout();
  }

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _CartPanelSlot) child.parentData = _CartPanelSlot();
  }

  @override
  void performLayout() {
    final top = firstChild!;
    final list = childAfter(top)!;
    final bottom = childAfter(list)!;
    final width = BoxConstraints.tightFor(width: constraints.maxWidth);
    top.layout(width, parentUsesSize: true);
    bottom.layout(width, parentUsesSize: true);
    final room = _height - top.size.height - bottom.size.height;
    final fits = room.isFinite && room >= _CartPanel.minList;
    // Too little room: up to minList, less only when the cart itself is shorter.
    list.layout(fits ? width.tighten(height: room) : width.copyWith(maxHeight: _CartPanel.minList), parentUsesSize: true);
    final content = top.size.height + list.size.height + bottom.size.height;
    final total = content > _height || !_height.isFinite ? content : _height;
    (top.parentData! as _CartPanelSlot).offset = Offset.zero;
    (list.parentData! as _CartPanelSlot).offset = Offset(0, top.size.height);
    (bottom.parentData! as _CartPanelSlot).offset = Offset(0, total - bottom.size.height);
    size = constraints.constrain(Size(constraints.maxWidth, total));
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      defaultHitTestChildren(result, position: position);

  @override
  void paint(PaintingContext context, Offset offset) => defaultPaint(context, offset);
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
