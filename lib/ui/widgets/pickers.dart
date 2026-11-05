import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/i18n.dart';
import '../../core/theme.dart';
import '../../core/util.dart';
import '../../data/biz.dart';
import '../../state/app_state.dart';
import 'common.dart';
import 'scanner.dart';

/// Search-and-pick a customer or supplier, with inline "add new".
Future<Contact?> pickContact(BuildContext context, String type) =>
    showDialog<Contact>(context: context, builder: (_) => _ContactPicker(type: type));

class _ContactPicker extends ConsumerStatefulWidget {
  final String type;
  const _ContactPicker({required this.type});
  @override
  ConsumerState<_ContactPicker> createState() => _ContactPickerState();
}

class _ContactPickerState extends ConsumerState<_ContactPicker> {
  final q = TextEditingController();
  final name = TextEditingController();
  final phone = TextEditingController();
  bool adding = false;

  @override
  void dispose() {
    q.dispose();
    name.dispose();
    phone.dispose();
    super.dispose();
  }

  Future<void> _add() async {
    final biz = ref.read(bizProvider);
    await guard(context, () async {
      final id = await biz.contacts.create(type: widget.type, name: name.text, phone: phone.text);
      final c = await biz.contacts.byId(id);
      if (mounted) Navigator.pop(context, c);
    });
  }

  @override
  Widget build(BuildContext context) {
    final biz = ref.watch(bizProvider);
    final isCustomer = widget.type == 'customer';
    return AppDialog(
      title: isCustomer ? T.selectCustomer.s : T.selectSupplier.s,
      icon: isCustomer ? Icons.person_search_outlined : Icons.storefront_outlined,
      width: 520,
      child: adding
          ? Column(children: [
              TextIn(controller: name, label: T.name.s, autofocus: true, icon: Icons.person_outline),
              const Gap(12),
              TextIn(controller: phone, label: T.phone.s, keyboard: TextInputType.phone, icon: Icons.phone_outlined, onSubmitted: (_) => _add()),
              const Gap(16),
              Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                TextButton(onPressed: () => setState(() => adding = false), child: Text(T.back.s)),
                const Gap(8),
                FilledButton(onPressed: _add, child: Text(T.save.s)),
              ]),
            ])
          : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(children: [
                Expanded(child: SearchBox(controller: q, hint: '${T.name.s} / ${T.phone.s}', autofocus: true, width: double.infinity, onChanged: (_) => setState(() {}))),
                const Gap(10),
                FilledButton.icon(
                  onPressed: () {
                    final t = q.text.trim();
                    if (RegExp(r'^[0-9০-৯+ -]+$').hasMatch(t)) {
                      phone.text = t;
                    } else {
                      name.text = t;
                    }
                    setState(() => adding = true);
                  },
                  icon: const Icon(Icons.person_add_alt_1_outlined, size: 18),
                  label: Text(isCustomer ? T.newCustomer.s : T.addSupplier.s),
                ),
              ]),
              const Gap(12),
              SizedBox(
                height: 340,
                child: StreamBuilder<List<ContactWithBalance>>(
                  stream: biz.contacts.watchContacts(widget.type, query: q.text, sort: ContactSort.recent),
                  builder: (context, snap) {
                    final list = snap.data ?? const [];
                    if (!snap.hasData) return const Loading();
                    if (list.isEmpty) return EmptyState(icon: Icons.person_off_outlined, text: T.noData.s);
                    return ListView.builder(
                      itemCount: list.length,
                      itemBuilder: (_, i) {
                        final c = list[i];
                        return TableRowX(
                          cols: const [Col('', flex: 5), Col('', flex: 3, align: TextAlign.right)],
                          onTap: () => Navigator.pop(context, c.contact),
                          cells: [
                            Row(children: [
                              Avatar(c.contact.name, size: 32),
                              const Gap(10),
                              Expanded(child: Cell2(c.contact.name, c.contact.phone == null ? null : digits(c.contact.phone!))),
                            ]),
                            c.balance.abs() < 0.01
                                ? Text(T.settled.s, style: Txt.tiny)
                                : Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                                    MoneyText(c.balance.abs(), tone: c.balance > 0 ? Tone.good : Tone.bad),
                                    Text(c.balance > 0 ? T.willGet.s : T.willGive.s, style: Txt.tiny),
                                  ]),
                          ],
                        );
                      },
                    );
                  },
                ),
              ),
            ]),
    );
  }
}

/// Type-ahead product search for forms (orders, purchases).
class ProductSearchField extends ConsumerStatefulWidget {
  final ValueChanged<Product> onPick;
  final ValueChanged<String>? onCustom;
  final String? hint;
  final bool autofocus;
  const ProductSearchField({super.key, required this.onPick, this.onCustom, this.hint, this.autofocus = false});

  @override
  ConsumerState<ProductSearchField> createState() => _ProductSearchFieldState();
}

class _ProductSearchFieldState extends ConsumerState<ProductSearchField> {
  final controller = TextEditingController();
  final focus = FocusNode();
  final link = LayerLink();
  final overlay = OverlayPortalController();
  List<Product> results = const [];
  int highlighted = 0;
  Timer? debounce;

  @override
  void initState() {
    super.initState();
    focus.addListener(() {
      if (!focus.hasFocus) Future.delayed(const Duration(milliseconds: 180), () => mounted ? overlay.hide() : null);
    });
  }

  @override
  void dispose() {
    debounce?.cancel();
    controller.dispose();
    focus.dispose();
    super.dispose();
  }

  void _search(String q) {
    debounce?.cancel();
    debounce = Timer(const Duration(milliseconds: 120), () async {
      final biz = ref.read(bizProvider);
      final exact = await biz.products.byCode(q);
      final list = exact != null ? [exact] : await biz.products.search(q, limit: 8);
      if (!mounted) return;
      setState(() {
        results = list;
        highlighted = 0;
      });
      if (q.trim().isNotEmpty) overlay.show();
    });
  }

  void _pick(Product p) {
    widget.onPick(p);
    controller.clear();
    setState(() => results = const []);
    overlay.hide();
    focus.requestFocus();
  }

  Future<void> _scanned(String code) async {
    final p = await ref.read(bizProvider).products.byCode(code);
    if (!mounted) return;
    if (p != null) {
      _pick(p);
    } else if (widget.onCustom != null) {
      widget.onCustom!(code);
    } else {
      toast(context, T.noProductFound.s, error: true);
    }
  }

  void _submit() {
    if (results.isNotEmpty) {
      _pick(results[highlighted.clamp(0, results.length - 1)]);
    } else if (controller.text.trim().isNotEmpty && widget.onCustom != null) {
      widget.onCustom!(controller.text.trim());
      controller.clear();
      overlay.hide();
    }
  }

  @override
  Widget build(BuildContext context) {
    return CompositedTransformTarget(
      link: link,
      child: OverlayPortal(
        controller: overlay,
        overlayChildBuilder: (_) => CompositedTransformFollower(
          link: link,
          targetAnchor: Alignment.bottomLeft,
          offset: const Offset(0, 4),
          child: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 460,
              child: Material(
                elevation: 8,
                color: C.card,
                borderRadius: BorderRadius.circular(12),
                child: Container(
                  constraints: const BoxConstraints(maxHeight: 320),
                  decoration: BoxDecoration(borderRadius: BorderRadius.circular(12), border: Border.all(color: C.line)),
                  child: results.isEmpty
                      ? Padding(
                          padding: const EdgeInsets.all(14),
                          child: Text(widget.onCustom == null ? T.noData.s : T.noProductFound.s, style: Txt.small),
                        )
                      : ListView.builder(
                          shrinkWrap: true,
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          itemCount: results.length,
                          itemBuilder: (_, i) {
                            final p = results[i];
                            return InkWell(
                              onTap: () => _pick(p),
                              child: Container(
                                color: i == highlighted ? C.brandSoft : null,
                                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                                child: Row(children: [
                                  Expanded(child: Cell2(p.name, [p.sku, p.barcode].whereType<String>().join(' · '))),
                                  if (p.trackStock)
                                    Padding(
                                      padding: const EdgeInsets.only(right: 12),
                                      child: Text(T.inStockN.f({'n': qty(p.stock)}),
                                          style: Txt.tiny.copyWith(color: p.stock <= 0 ? C.outRed : C.ink3)),
                                    ),
                                  MoneyText(p.salePrice),
                                ]),
                              ),
                            );
                          },
                        ),
                ),
              ),
            ),
          ),
        ),
        child: CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.arrowDown): () => setState(() => highlighted = (highlighted + 1).clamp(0, results.isEmpty ? 0 : results.length - 1)),
            const SingleActivator(LogicalKeyboardKey.arrowUp): () => setState(() => highlighted = (highlighted - 1).clamp(0, results.isEmpty ? 0 : results.length - 1)),
          },
          child: TextField(
            controller: controller,
            focusNode: focus,
            autofocus: widget.autofocus,
            onChanged: _search,
            onSubmitted: (_) {
              _submit();
              focus.requestFocus();
            },
            decoration: InputDecoration(
              hintText: widget.hint ?? T.scanOrSearch.s,
              prefixIcon: const Icon(Icons.qr_code_scanner_rounded, size: 20),
              suffixIcon: ScanButton(onCode: _scanned),
            ),
          ),
        ),
      ),
    );
  }
}

/// Show a stock badge consistently.
Widget stockBadge(Product p) {
  if (!p.trackStock) return const SizedBox.shrink();
  if (p.stock <= 0) return Pill(T.outOfStock.s, tone: Tone.bad);
  if (p.stock <= p.lowStock) return Pill('${qty(p.stock)} ${unitLabel(p.unit)}', tone: Tone.warn);
  return Pill('${qty(p.stock)} ${unitLabel(p.unit)}', tone: Tone.good);
}

// Kept for callers that want a quick numeric parse.
double parseField(TextEditingController c, [double fallback = 0]) => parseNum(c.text, fallback);
