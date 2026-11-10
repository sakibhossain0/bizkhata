import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/format.dart';
import '../../core/i18n.dart';
import '../../core/theme.dart';
import '../../core/util.dart';
import '../../couriers/registry.dart';
import '../../data/biz.dart';
import '../../state/app_state.dart';
import '../../state/website_state.dart';
import '../../services/templates.dart';
import '../widgets/common.dart';

final _orders = StreamProvider.autoDispose.family<List<SaleRow>, (DateRange, String, String)>((ref, a) => ref
    .watch(bizProvider)
    .sales
    .watchList(range: a.$1, query: a.$2, channel: 'online', statuses: a.$3 == 'all' ? null : [a.$3]));
final _counts = StreamProvider.autoDispose((ref) => ref.watch(bizProvider).orders.watchStatusCounts());

class OrdersScreen extends ConsumerStatefulWidget {
  const OrdersScreen({super.key});
  @override
  ConsumerState<OrdersScreen> createState() => _OrdersScreenState();
}

class _OrdersScreenState extends ConsumerState<OrdersScreen> {
  String tab = 'pending';
  String query = '';
  RangeSelection range = RangeSelection.of(RangePreset.all);
  final selected = <int>{};
  bool syncing = false;
  String? progress;

  static const tabs = ['pending', 'confirmed', 'booked', 'delivered', 'partial', 'returned', 'cancelled', 'all'];
  static const cols = [
    Col('', flex: 1),
    Col('', flex: 4),
    Col('', flex: 5),
    Col('', flex: 3),
    Col('', flex: 3, align: TextAlign.right),
    Col('', flex: 4),
    Col('', flex: 3, align: TextAlign.right),
  ];

  bool get selectable => tab == 'pending' || tab == 'confirmed';

  Future<void> _sync() async {
    setState(() {
      syncing = true;
      progress = null;
    });
    final biz = ref.read(bizProvider);
    try {
      final s = await biz.orders.syncStatuses(onProgress: (d, t) {
        if (mounted) setState(() => progress = '${digits('$d')}/${digits('$t')}');
      });
      for (final id in s.deliveredIds) {
        unawaited(autoNotifyOrder(biz, id, MsgKind.delivered));
      }
      if (!mounted) return;
      toast(context, T.syncDone.f({'n': number(s.checked), 'd': number(s.delivered), 'r': number(s.returned)}));
      if (s.partial > 0) toast(context, T.partialNeedsReview.f({'n': number(s.partial)}), error: true);
      if (s.errors.isNotEmpty) toast(context, s.errors.first, error: true);
    } catch (e) {
      if (mounted) toast(context, errorText(e), error: true);
    } finally {
      if (mounted) setState(() => syncing = false);
    }
  }

  Future<void> _bulkBook() async {
    final biz = ref.read(bizProvider);
    final cfg = await biz.orders.courierConfig();
    if (!mounted) return;
    final configured = cfg.configured;
    if (configured.isEmpty) {
      toast(context, T.configureCourier.s, error: true);
      return;
    }
    var courier = configured.contains(cfg.defaultCourier) ? cfg.defaultCourier : configured.first;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AppDialog(
          title: '${T.bookCourier.s} · ${digits('${selected.length}')}',
          icon: Icons.local_shipping_outlined,
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(T.cancel.s)),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(T.bookCourier.s)),
          ],
          child: Wrap(spacing: 8, children: [
            for (final c in configured)
              ChoiceChip(label: Text(courierNames[c]!), selected: courier == c, onSelected: (_) => setD(() => courier = c)),
          ]),
        ),
      ),
    );
    if (ok != true || !mounted) return;
    var done = 0;
    final errors = <String>[];
    for (final id in selected.toList()) {
      try {
        await biz.orders.book(id, courier);
        unawaited(autoNotifyOrder(biz, id, MsgKind.shipped));
        done++;
      } catch (e) {
        errors.add(errorText(e));
      }
    }
    if (!mounted) return;
    setState(() => selected.clear());
    toast(context, '${courierNames[courier]}: ${digits('$done')} ✓${errors.isEmpty ? '' : ' · ${errors.first}'}', error: errors.isNotEmpty);
  }

  Future<void> _bulkConfirm() async {
    final biz = ref.read(bizProvider);
    for (final id in selected.toList()) {
      await biz.orders.confirm(id);
      unawaited(autoNotifyOrder(biz, id, MsgKind.confirmed));
    }
    if (mounted) setState(() => selected.clear());
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider).value ?? const {};
    if (!settings.flag(K.onlineEnabled)) {
      return EmptyState(
        icon: Icons.local_shipping_outlined,
        text: T.onlineOff.s,
        action: FilledButton(
          onPressed: () => ref.read(bizProvider).settings.setFlag(K.onlineEnabled, true),
          child: Text(T.turnOn.s),
        ),
      );
    }
    final cfg = CourierConfig(settings.json(K.courierConfig));
    final counts = ref.watch(_counts).value ?? const {};
    final rows = ref.watch(_orders((range.range, query, tab)));
    final all = counts.values.fold<int>(0, (a, b) => a + b);
    final web = ref.watch(websiteProvider);

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      PageHeader(
        title: T.orders.s,
        subtitle: range.label,
        actions: [
          SearchBox(hint: '${T.phone.s} / ${T.invoiceNo.s} / CID', onChanged: (v) => setState(() => query = v), width: 240),
          RangeButton(value: range, onChanged: (r) => setState(() => range = r)),
          if (web.config.ready)
            OutlinedButton.icon(
              onPressed: web.busy ? null : () => guard(context, () => ref.read(websiteProvider.notifier).syncNow()),
              icon: web.busy
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.language_rounded, size: 18),
              label: Text(T.webFetch.s),
            ),
          OutlinedButton.icon(
            onPressed: syncing ? null : _sync,
            icon: syncing
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.sync_rounded, size: 18),
            label: Text(syncing && progress != null ? progress! : T.syncCourier.s),
          ),
          FilledButton.icon(
            onPressed: () => context.go('/orders/new'),
            icon: const Icon(Icons.add_rounded, size: 19),
            label: Text(T.newOrder.s),
          ),
        ],
      ),
      if (cfg.testMode)
        Container(
          margin: EdgeInsets.fromLTRB(context.gutter, 0, context.gutter, 12),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          decoration: BoxDecoration(color: C.warnSoft, borderRadius: BorderRadius.circular(10)),
          child: Row(children: [
            const Icon(Icons.science_outlined, size: 18, color: C.warn),
            const Gap(8),
            Expanded(child: Text(T.testModeOn.s, style: Txt.small.copyWith(color: C.warn))),
            TextButton(onPressed: () => context.go('/settings'), child: Text(T.settings.s)),
          ]),
        ),
      SizedBox(
        height: 44,
        child: ListView(
          scrollDirection: Axis.horizontal,
          padding: EdgeInsets.symmetric(horizontal: context.gutter),
          children: [
            for (final t in tabs)
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: _TabChip(
                  label: t == 'all' ? T.all.s : tKey('st', t),
                  count: t == 'all' ? all : (counts[t] ?? 0),
                  selected: tab == t,
                  tone: t == 'all' ? Tone.neutral : statusTone(t),
                  onTap: () => setState(() {
                    tab = t;
                    selected.clear();
                  }),
                ),
              ),
          ],
        ),
      ),
      if (selected.isNotEmpty)
        Container(
          margin: EdgeInsets.fromLTRB(context.gutter, 6, context.gutter, 0),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          decoration: BoxDecoration(color: C.brand, borderRadius: BorderRadius.circular(10)),
          child: Row(children: [
            Text('${digits('${selected.length}')} ${T.select.s.toLowerCase()}',
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
            const Spacer(),
            if (tab == 'pending')
              TextButton(
                style: TextButton.styleFrom(foregroundColor: Colors.white),
                onPressed: _bulkConfirm,
                child: Text(T.confirmOrder.s),
              ),
            TextButton.icon(
              style: TextButton.styleFrom(foregroundColor: C.marigold),
              onPressed: _bulkBook,
              icon: const Icon(Icons.local_shipping_outlined, size: 18),
              label: Text(T.bookCourier.s),
            ),
            IconButton(
              onPressed: () => setState(() => selected.clear()),
              icon: const Icon(Icons.close_rounded, color: Colors.white70, size: 18),
            ),
          ]),
        ),
      const Gap(8),
      Expanded(
        child: Container(
          margin: EdgeInsets.fromLTRB(context.gutter, 0, context.gutter, 24),
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(color: C.card, borderRadius: BorderRadius.circular(14), border: Border.all(color: C.line)),
          child: Column(children: [
            TableHead([
              const Col('', flex: 1),
              Col(T.invoice.s, flex: 4),
              Col(T.customer.s, flex: 5),
              Col(T.area.s, flex: 3),
              Col(T.cod.s, flex: 3, align: TextAlign.right),
              Col(T.selectCourier.s, flex: 4),
              Col(T.status.s, flex: 3, align: TextAlign.right),
            ]),
            Expanded(
              child: AsyncView(rows, builder: (list) {
                if (list.isEmpty) {
                  return EmptyState(
                    icon: Icons.inbox_outlined,
                    text: T.noData.s,
                    action: FilledButton.icon(
                        onPressed: () => context.go('/orders/new'), icon: const Icon(Icons.add, size: 18), label: Text(T.newOrder.s)),
                  );
                }
                return ListView.builder(
                  itemCount: list.length,
                  itemBuilder: (_, i) {
                    final r = list[i];
                    final s = r.sale;
                    final canSelect = s.status == 'pending' || s.status == 'confirmed';
                    return TableRowX(
                      cols: cols,
                      selected: selected.contains(s.id),
                      onTap: () => context.go('/orders/${s.id}'),
                      cells: [
                        canSelect && selectable
                            ? Checkbox(
                                value: selected.contains(s.id),
                                onChanged: (v) => setState(() => v == true ? selected.add(s.id) : selected.remove(s.id)),
                              )
                            : const SizedBox(),
                        Cell2(s.invoiceNo, friendlyDate(s.date)),
                        Cell2(s.shipName ?? r.contactName ?? '', s.shipPhone == null ? null : digits(s.shipPhone!)),
                        Cell2(s.shipArea ?? '—', s.shipCity, Txt.small),
                        MoneyText(s.status == 'delivered' || s.status == 'partial' ? s.total : r.due),
                        r.courier == null
                            ? Text('—', style: Txt.small)
                            : Cell2(courierNames[r.courier] ?? r.courier!, [r.consignmentId, r.courierStatus].whereType<String>().join(' · '),
                                Txt.body),
                        StatusPill(s.status),
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
}

class _TabChip extends StatelessWidget {
  final String label;
  final int count;
  final bool selected;
  final Tone tone;
  final VoidCallback onTap;
  const _TabChip({required this.label, required this.count, required this.selected, required this.tone, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? C.ink : C.card,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(10), border: Border.all(color: selected ? C.ink : C.line)),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Text(label, style: TextStyle(fontFamily: kBody, fontWeight: FontWeight.w600, fontSize: 13.5, color: selected ? Colors.white : C.ink)),
            const Gap(8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                color: selected ? Colors.white.withValues(alpha: 0.16) : tone.bg,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(number(count),
                  style: TextStyle(fontFamily: kBody, fontSize: 11.5, fontWeight: FontWeight.w700, color: selected ? Colors.white : tone.fg)),
            ),
          ]),
        ),
      ),
    );
  }
}
