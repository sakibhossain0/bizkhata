import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/format.dart';
import '../../core/i18n.dart';
import '../../core/theme.dart';
import '../../data/biz.dart';
import '../../state/app_state.dart';
import 'common.dart';

class _Hit {
  final String group;
  final IconData icon;
  final String title;
  final String sub;
  final String trailing;
  final String path;
  const _Hit(this.group, this.icon, this.title, this.sub, this.trailing, this.path);
}

/// Ctrl+K: one box that finds products, customers, suppliers, invoices and orders.
Future<void> showGlobalSearch(BuildContext context) {
  final router = GoRouter.of(context);
  return showDialog(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.35),
    builder: (_) => _SearchDialog(onOpen: router.go),
  );
}

class _SearchDialog extends ConsumerStatefulWidget {
  final void Function(String path) onOpen;
  const _SearchDialog({required this.onOpen});

  @override
  ConsumerState<_SearchDialog> createState() => _SearchDialogState();
}

class _SearchDialogState extends ConsumerState<_SearchDialog> {
  final query = TextEditingController();
  final scroll = ScrollController();
  List<_Hit> hits = const [];
  int selected = 0;
  bool searching = false;
  Timer? _debounce;
  int _seq = 0;

  @override
  void dispose() {
    _debounce?.cancel();
    query.dispose();
    scroll.dispose();
    super.dispose();
  }

  void _changed(String _) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 160), _run);
  }

  Future<void> _run() async {
    final term = query.text.trim();
    final seq = ++_seq;
    if (term.isEmpty) {
      setState(() {
        hits = const [];
        selected = 0;
      });
      return;
    }
    setState(() => searching = true);
    final biz = ref.read(bizProvider);
    final actor = ref.read(actorProvider);
    final online = (ref.read(settingsProvider).value ?? const {}).flag(K.onlineEnabled);
    final results = await Future.wait([
      biz.products.search(term, limit: 6),
      biz.contacts.search('customer', term, limit: 5),
      actor.can(Cap.suppliers) ? biz.contacts.search('supplier', term, limit: 4) : Future.value(<Contact>[]),
      biz.sales.searchDocs(term, limit: 8),
    ]);
    if (!mounted || seq != _seq) return;
    final products = results[0] as List<Product>;
    final customers = results[1] as List<Contact>;
    final suppliers = results[2] as List<Contact>;
    final docs = results[3] as List<SaleRow>;
    setState(() {
      searching = false;
      selected = 0;
      hits = [
        for (final p in products)
          _Hit(T.products.s, Icons.inventory_2_outlined, p.name,
              [if (p.barcode != null && p.barcode!.isNotEmpty) p.barcode!, if (p.trackStock) '${T.stock.s}: ${qty(p.stock)} ${unitLabel(p.unit)}'].join(' · '),
              money(p.salePrice), '/products/${p.id}'),
        for (final c in customers)
          _Hit(T.customers.s, Icons.person_outline_rounded, c.name, c.phone ?? '', '', '/customers/${c.id}'),
        for (final c in suppliers)
          _Hit(T.suppliers.s, Icons.storefront_outlined, c.name, c.phone ?? '', '', '/suppliers/${c.id}'),
        for (final d in docs)
          if (d.sale.channel != 'online' || online)
            _Hit(
              d.sale.channel == 'online' ? T.orders.s : T.invoices.s,
              d.sale.channel == 'online' ? Icons.local_shipping_outlined : Icons.receipt_long_outlined,
              d.sale.invoiceNo,
              [d.contactName ?? d.sale.shipName ?? T.walkIn.s, friendlyDate(d.sale.date)].join(' · '),
              money(d.sale.total),
              d.sale.channel == 'online' ? '/orders/${d.sale.id}' : '/sales/${d.sale.id}',
            ),
      ];
    });
  }

  void _open(_Hit h) {
    Navigator.pop(context);
    widget.onOpen(h.path);
  }

  void _move(int delta) {
    if (hits.isEmpty) return;
    setState(() => selected = (selected + delta).clamp(0, hits.length - 1));
    // Keep the highlighted row in view (rows are ~58px, headers ~30px).
    final target = selected * 58.0;
    if (scroll.hasClients) {
      final pos = scroll.position;
      if (target < pos.pixels) scroll.jumpTo(target);
      if (target + 58 > pos.pixels + pos.viewportDimension) scroll.jumpTo((target + 88 - pos.viewportDimension).clamp(0, pos.maxScrollExtent));
    }
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final phone = size.width < 600;
    String? lastGroup;
    return Align(
      alignment: phone ? Alignment.topCenter : const Alignment(0, -0.55),
      child: Padding(
        padding: EdgeInsets.fromLTRB(phone ? 8 : 24, phone ? 8 : 24, phone ? 8 : 24, 24),
        child: Material(
          color: C.card,
          elevation: 12,
          borderRadius: BorderRadius.circular(16),
          clipBehavior: Clip.antiAlias,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: 620, maxHeight: size.height * (phone ? 0.85 : 0.7)),
            child: CallbackShortcuts(
              bindings: {
                const SingleActivator(LogicalKeyboardKey.arrowDown): () => _move(1),
                const SingleActivator(LogicalKeyboardKey.arrowUp): () => _move(-1),
                const SingleActivator(LogicalKeyboardKey.escape): () => Navigator.pop(context),
              },
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 12, 10, 8),
                  child: TextField(
                    key: const ValueKey('global-search'),
                    controller: query,
                    autofocus: true,
                    onChanged: _changed,
                    onSubmitted: (_) {
                      if (hits.isNotEmpty) _open(hits[selected]);
                    },
                    textInputAction: TextInputAction.search,
                    style: Txt.body.copyWith(fontSize: 16),
                    decoration: InputDecoration(
                      hintText: T.searchAll.s,
                      prefixIcon: const Icon(Icons.search_rounded),
                      suffixIcon: searching
                          ? const Padding(
                              padding: EdgeInsets.all(14),
                              child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)))
                          : IconButton(
                              tooltip: T.close.s, onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close_rounded)),
                    ),
                  ),
                ),
                const Divider(height: 1),
                Flexible(
                  child: hits.isEmpty
                      ? Padding(
                          padding: const EdgeInsets.fromLTRB(20, 22, 20, 26),
                          child: Column(mainAxisSize: MainAxisSize.min, children: [
                            Icon(query.text.trim().isEmpty ? Icons.manage_search_rounded : Icons.search_off_rounded, size: 34, color: C.ink3),
                            const Gap(8),
                            Text(query.text.trim().isEmpty ? T.typeToSearch.s : (searching ? '…' : T.noResults.s),
                                style: Txt.small, textAlign: TextAlign.center),
                            if (!phone && query.text.trim().isEmpty) ...[
                              const Gap(10),
                              Row(mainAxisSize: MainAxisSize.min, children: [
                                const KeyCap('↑'),
                                const SizedBox(width: 4),
                                const KeyCap('↓'),
                                const SizedBox(width: 6),
                                Text('·', style: Txt.tiny),
                                const SizedBox(width: 6),
                                const KeyCap('Enter'),
                                const SizedBox(width: 6),
                                Text('·', style: Txt.tiny),
                                const SizedBox(width: 6),
                                const KeyCap('Esc'),
                              ]),
                            ],
                          ]),
                        )
                      : ListView.builder(
                          controller: scroll,
                          padding: const EdgeInsets.fromLTRB(8, 6, 8, 10),
                          shrinkWrap: true,
                          itemCount: hits.length,
                          itemBuilder: (_, i) {
                            final h = hits[i];
                            final header = h.group != lastGroup;
                            lastGroup = h.group;
                            return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                              if (header)
                                Padding(
                                  padding: const EdgeInsets.fromLTRB(10, 10, 10, 4),
                                  child: Text(h.group.toUpperCase(), style: Txt.caps),
                                ),
                              _HitTile(hit: h, selected: i == selected, onTap: () => _open(h)),
                            ]);
                          },
                        ),
                ),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

class _HitTile extends StatelessWidget {
  final _Hit hit;
  final bool selected;
  final VoidCallback onTap;
  const _HitTile({required this.hit, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? C.brandSoft : Colors.transparent,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          child: Row(children: [
            Icon(hit.icon, size: 20, color: selected ? C.brand : C.ink2),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(hit.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: Txt.strong),
                if (hit.sub.isNotEmpty) Text(hit.sub, maxLines: 1, overflow: TextOverflow.ellipsis, style: Txt.small),
              ]),
            ),
            if (hit.trailing.isNotEmpty) ...[
              const SizedBox(width: 10),
              Text(hit.trailing, style: Txt.strong.copyWith(color: C.ink2)),
            ],
          ]),
        ),
      ),
    );
  }
}
