import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:path/path.dart' as p;

import '../../core/format.dart';
import '../../core/i18n.dart';
import '../../core/theme.dart';
import '../../core/util.dart';
import '../../data/biz.dart';
import '../../data/business_store.dart';
import '../../data/seed.dart';
import '../../services/messaging.dart';
import '../../services/print_service.dart';
import '../../state/app_state.dart';
import '../widgets/common.dart';
import '../widgets/scanner.dart';
import '../widgets/pickers.dart';

final _products = StreamProvider.autoDispose.family<List<Product>, (String, int?, StockFilter)>(
    (ref, a) => ref.watch(bizProvider).products.watchProducts(query: a.$1, categoryId: a.$2, filter: a.$3));
final _cats = StreamProvider.autoDispose((ref) => ref.watch(bizProvider).products.watchCategories());
final _stockValue = StreamProvider.autoDispose((ref) => ref.watch(bizProvider).reports.watchStockValue());
final _product = StreamProvider.autoDispose.family<Product?, int>((ref, id) => ref.watch(bizProvider).products.watchById(id));
final _moves = StreamProvider.autoDispose.family<List<StockMove>, int>((ref, id) => ref.watch(bizProvider).products.watchMoves(id));

class ProductsScreen extends ConsumerStatefulWidget {
  final int? selectedId;
  const ProductsScreen({super.key, this.selectedId});
  @override
  ConsumerState<ProductsScreen> createState() => _ProductsScreenState();
}

class _ProductsScreenState extends ConsumerState<ProductsScreen> {
  String query = '';
  int? categoryId;
  StockFilter filter = StockFilter.all;

  static const cols = [
    Col('', flex: 6),
    Col('', flex: 3),
    Col('', flex: 3, align: TextAlign.right),
    Col('', flex: 3, align: TextAlign.right),
    Col('', flex: 3, align: TextAlign.right),
    Col('', flex: 2, align: TextAlign.right),
  ];

  /// Without cost and margin, for staff who may not see costs.
  static const colsNoCost = [
    Col('', flex: 6),
    Col('', flex: 3),
    Col('', flex: 3, align: TextAlign.right),
    Col('', flex: 3, align: TextAlign.right),
  ];

  @override
  Widget build(BuildContext context) {
    final list = ref.watch(_products((query, categoryId, filter)));
    final cats = ref.watch(_cats).value ?? const <ProductCategory>[];
    final catName = {for (final c in cats) c.id: c.name};
    final sv = ref.watch(_stockValue).value;
    final selected = widget.selectedId;
    final actor = ref.watch(actorProvider);
    final seeCost = actor.can(Cap.seeCost);
    final canEdit = actor.can(Cap.editProducts);

    final header = [
      Col(T.productName.s, flex: 6),
      Col(T.category.s, flex: 3),
      Col(T.stock.s, flex: 3, align: TextAlign.right),
      if (seeCost) Col(T.costPrice.s, flex: 3, align: TextAlign.right),
      Col(T.salePrice.s, flex: 3, align: TextAlign.right),
      if (seeCost) Col(T.margin.s, flex: 2, align: TextAlign.right),
    ];

    // Narrow screens show one pane at a time.
    if (context.isCompact && selected != null) {
      return Container(color: C.card, child: _ProductPanel(id: selected));
    }

    final segmented = SegmentedButton<StockFilter>(
      showSelectedIcon: false,
      style: SegmentedButton.styleFrom(
        selectedBackgroundColor: C.brandSoft,
        selectedForegroundColor: C.brand,
        side: const BorderSide(color: C.line),
      ),
      segments: [
        ButtonSegment(value: StockFilter.all, label: Text(T.all.s)),
        ButtonSegment(value: StockFilter.low, label: Text(T.lowStock.s)),
        ButtonSegment(value: StockFilter.out, label: Text(T.outOfStock.s)),
      ],
      selected: {filter},
      onSelectionChanged: (s) => setState(() => filter = s.first),
    );
    final catChips = SizedBox(
      height: 40,
      child: ListView(scrollDirection: Axis.horizontal, children: [
        ChoiceChip(label: Text(T.all.s), selected: categoryId == null, onSelected: (_) => setState(() => categoryId = null)),
        for (final c in cats) ...[
          const Gap(6),
          ChoiceChip(label: Text(c.name), selected: categoryId == c.id, onSelected: (_) => setState(() => categoryId = c.id)),
        ],
        if (canEdit) ...[
          const Gap(6),
          ActionChip(
            avatar: const Icon(Icons.add_rounded, size: 16),
            label: Text(T.addCategory.s),
            onPressed: () => _addCategory(context, ref),
          ),
        ],
      ]),
    );

    return CallbackShortcuts(
      bindings: {
        if (canEdit) const SingleActivator(LogicalKeyboardKey.keyN, control: true): () => showProductForm(context, ref),
      },
      child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            PageHeader(
              title: T.products.s,
              subtitle: list.value == null ? null : T.productsCount.f({'n': number(list.value!.length)}),
              actions: [
                SearchBox(hint: '${T.search.s}…', onChanged: (v) => setState(() => query = v), width: 240),
                if (canEdit)
                PopupMenuButton<String>(
                  tooltip: T.more.s,
                  position: PopupMenuPosition.under,
                  onSelected: (v) => switch (v) {
                    'import' => _import(context),
                    'template' => guard(context, () => saveCsv('bizkhata-products-template', [
                          ProductRepo.importHeaders,
                          ['Miniket Rice 5kg', 'Rice & Grains', 'bag', 340, 390, 375, 40, 8, 'P1001', '8900010001'],
                        ])),
                    _ => _exportList(context),
                  },
                  itemBuilder: (_) => [
                    PopupMenuItem(value: 'import', child: Text(T.importCsv.s)),
                    PopupMenuItem(value: 'template', child: Text(T.downloadTemplate.s)),
                    PopupMenuItem(value: 'export', child: Text(T.exportStock.s)),
                  ],
                  child: IgnorePointer(
                    child: OutlinedButton.icon(onPressed: () {}, icon: const Icon(Icons.upload_file_rounded, size: 18), label: Text(T.more.s)),
                  ),
                ),
                if (canEdit)
                  FilledButton.icon(
                    onPressed: () => showProductForm(context, ref),
                    icon: const Icon(Icons.add_rounded, size: 19),
                    label: Text(T.addProduct.s),
                  ),
              ],
            ),
            Padding(
              padding: EdgeInsets.fromLTRB(context.gutter, 0, context.gutter, 12),
              child: AutoGrid(minItemWidth: 150, gap: 10, children: [
                if (seeCost) _miniStat(T.stockValueCost.s, money(sv?.atCost ?? 0), Tone.brand),
                _miniStat(T.stockValueSale.s, money(sv?.atSale ?? 0), Tone.good),
                _miniStat(T.lowStock.s, number(sv?.lowCount ?? 0), Tone.warn,
                    onTap: () => setState(() => filter = StockFilter.low)),
                _miniStat(T.outOfStock.s, number(sv?.outCount ?? 0), Tone.bad,
                    onTap: () => setState(() => filter = StockFilter.out)),
              ]),
            ),
            Padding(
              padding: EdgeInsets.fromLTRB(context.gutter, 0, context.gutter, 10),
              child: context.isPhone
                  ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: [segmented, const Gap(8), catChips])
                  : Row(children: [segmented, const Gap(10), Expanded(child: catChips)]),
            ),
            Expanded(
              child: Padding(
                padding: EdgeInsets.fromLTRB(context.gutter, 0, context.gutter, 24),
                child: Container(
                  clipBehavior: Clip.antiAlias,
                  decoration: BoxDecoration(color: C.card, borderRadius: BorderRadius.circular(14), border: Border.all(color: C.line)),
                  child: Column(children: [
                    TableHead(header),
                    Expanded(
                      child: AsyncView(list, builder: (rows) {
                        if (rows.isEmpty) {
                          return EmptyState(
                            icon: Icons.inventory_2_outlined,
                            text: T.noProducts.s,
                            action: !canEdit
                                ? null
                                : FilledButton.icon(
                                    onPressed: () => showProductForm(context, ref),
                                    icon: const Icon(Icons.add_rounded, size: 18),
                                    label: Text(T.addProduct.s)),
                          );
                        }
                        return ListView.builder(
                          itemCount: rows.length,
                          itemBuilder: (_, i) {
                            final pr = rows[i];
                            final margin = pr.salePrice > 0 ? (pr.salePrice - pr.costPrice) / pr.salePrice * 100 : 0.0;
                            return TableRowX(
                              cols: seeCost ? cols : colsNoCost,
                              selected: pr.id == selected,
                              onTap: () => context.go(pr.id == selected ? '/products' : '/products/${pr.id}'),
                              cells: [
                                Row(children: [
                                  _thumb(pr),
                                  const Gap(10),
                                  Expanded(child: Cell2(pr.name, [pr.sku, pr.barcode].whereType<String>().join(' · '))),
                                ]),
                                Text(catName[pr.categoryId] ?? '—', style: Txt.small, overflow: TextOverflow.ellipsis),
                                pr.trackStock ? stockBadge(pr) : Text('—', style: Txt.small),
                                if (seeCost) MoneyText(pr.costPrice, style: Txt.num.copyWith(color: C.ink2, fontWeight: FontWeight.w500)),
                                MoneyText(pr.salePrice),
                                if (seeCost) Text(pct(margin), style: Txt.small.copyWith(color: margin < 0 ? C.outRed : C.ink2)),
                              ],
                            );
                          },
                        );
                      }),
                    ),
                  ]),
                ),
              ),
            ),
          ]),
        ),
        if (!context.isCompact)
        AnimatedSize(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
          child: selected == null
              ? const SizedBox(width: 0)
              : Container(
                  width: 380,
                  decoration: const BoxDecoration(color: C.card, border: Border(left: BorderSide(color: C.line))),
                  child: _ProductPanel(id: selected),
                ),
        ),
      ]),
    );
  }

  Future<void> _import(BuildContext context) async {
    final ok = await confirmDialog(context, title: T.importCsv.s, message: T.importHint.s, confirmLabel: T.open.s);
    if (!ok) return;
    final f = await FilePicker.pickFile(type: FileType.custom, allowedExtensions: ['csv', 'txt']);
    if (f == null || !context.mounted) return;
    await guard(context, () async {
      final bytes = await f.readAsBytes();
      final r = await ref.read(bizProvider).products.importCsv(parseCsv(utf8.decode(bytes, allowMalformed: true)));
      if (context.mounted) toast(context, T.importDone.f({'c': number(r.created), 'u': number(r.updated), 's': number(r.skipped)}));
    });
  }

  Future<void> _exportList(BuildContext context) async {
    final biz = ref.read(bizProvider);
    await guard(context, () async {
      final cats = {for (final c in await biz.products.watchCategories().first) c.id: c.name};
      final all = await biz.products.watchProducts().first;
      await saveCsv('bizkhata-products-${fileStamp(DateTime.now())}', [
        ProductRepo.importHeaders,
        for (final p in all)
          [p.name, cats[p.categoryId] ?? '', p.unit, p.costPrice, p.salePrice, p.wholesalePrice, p.stock, p.lowStock, p.sku, p.barcode],
      ]);
    });
  }

  Widget _miniStat(String label, String value, Tone tone, {VoidCallback? onTap}) => InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(color: C.card, borderRadius: BorderRadius.circular(12), border: Border.all(color: C.line)),
            child: Row(children: [
              Container(width: 4, height: 30, decoration: BoxDecoration(color: tone.fg, borderRadius: BorderRadius.circular(2))),
              const Gap(10),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(label, style: Txt.tiny, maxLines: 1, overflow: TextOverflow.ellipsis),
                  Text(value, style: Txt.strong.copyWith(fontSize: 16)),
                ]),
              ),
            ]),
          ),
        );
}

Widget _thumb(Product p, {double size = 36}) {
  if (p.imagePath != null && File(p.imagePath!).existsSync()) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(size * 0.25),
      child: Image.file(File(p.imagePath!), width: size, height: size, fit: BoxFit.cover, cacheWidth: (size * 3).toInt()),
    );
  }
  return Avatar(p.name, size: size);
}

Future<void> _addCategory(BuildContext context, WidgetRef ref) async {
  final c = TextEditingController();
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AppDialog(
      title: T.addCategory.s,
      icon: Icons.label_outline_rounded,
      width: 400,
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(T.cancel.s)),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(T.save.s)),
      ],
      child: TextIn(controller: c, label: T.name.s, autofocus: true, onSubmitted: (_) => Navigator.pop(ctx, true)),
    ),
  );
  if (ok == true && context.mounted) {
    await guard(context, () => ref.read(bizProvider).products.addCategory(c.text));
  }
  c.dispose();
}

/// EAN-13 starting with 200 (reserved for in-store codes).
String generateBarcode() {
  final r = Random();
  final body = '200${List.generate(9, (_) => r.nextInt(10)).join()}';
  var sum = 0;
  for (var i = 0; i < 12; i++) {
    sum += int.parse(body[i]) * (i.isEven ? 1 : 3);
  }
  return '$body${(10 - sum % 10) % 10}';
}

// =============================================================== detail panel

class _ProductPanel extends ConsumerWidget {
  final int id;
  const _ProductPanel({required this.id});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final prod = ref.watch(_product(id));
    final moves = ref.watch(_moves(id));
    final actor = ref.watch(actorProvider);
    final canEdit = actor.can(Cap.editProducts);
    final biz = ref.watch(bizProvider);
    return AsyncView(prod, builder: (p) {
      if (p == null) return EmptyState(icon: Icons.inventory_2_outlined, text: T.e_not_found.s);
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 10, 6),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            _thumb(p, size: 52),
            const Gap(12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(p.name, style: Txt.display(19), maxLines: 3),
                const Gap(4),
                if ((p.sku ?? p.barcode) != null) Text([p.sku, p.barcode].whereType<String>().join(' · '), style: Txt.tiny),
              ]),
            ),
            IconButton(onPressed: () => context.go('/products'), icon: const Icon(Icons.close_rounded, size: 20)),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
          child: Row(children: [
            Expanded(child: _kv(T.salePrice.s, money(p.salePrice), big: true)),
            Expanded(
                child: _kv(T.stock.s, p.trackStock ? '${qty(p.stock)} ${unitLabel(p.unit)}' : '—',
                    big: true, color: p.trackStock && p.stock <= p.lowStock ? C.outRed : null)),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
          child: Row(children: [
            if (actor.can(Cap.seeCost)) Expanded(child: _kv(T.costPrice.s, money(p.costPrice))),
            Expanded(child: _kv(T.wholesale.s, p.wholesalePrice > 0 ? money(p.wholesalePrice) : '—')),
            Expanded(child: _kv(T.lowStockAlert.s, qty(p.lowStock))),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: Wrap(spacing: 8, runSpacing: 8, children: [
            if (canEdit)
            FilledButton.icon(
              onPressed: () => showProductForm(context, ref, product: p),
              icon: const Icon(Icons.edit_outlined, size: 17),
              label: Text(T.edit.s),
            ),
            if (p.trackStock && canEdit)
              OutlinedButton.icon(
                onPressed: () => _adjust(context, ref, p),
                icon: const Icon(Icons.tune_rounded, size: 17),
                label: Text(T.adjustStock.s),
              ),
            OutlinedButton.icon(
              onPressed: () => _labels(context, ref, p),
              icon: const Icon(Icons.qr_code_2_rounded, size: 17),
              label: Text(T.printLabels.s),
            ),
            if (canEdit)
            IconButton(
              tooltip: T.delete.s,
              onPressed: () async {
                final ok = await confirmDialog(context,
                    title: '${T.delete.s}: ${p.name}', message: T.archivedNote.s, confirmLabel: T.delete.s, danger: true);
                if (!ok || !context.mounted) return;
                if (await guard(context, () => biz.products.delete(p.id), success: T.deleted.s) && context.mounted) {
                  context.go('/products');
                }
              },
              icon: const Icon(Icons.delete_outline_rounded, color: C.outRed),
            ),
          ]),
        ),
        const Divider(),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 6),
          child: Text(T.stockHistory.s, style: Txt.strong),
        ),
        Expanded(
          child: AsyncView(moves, builder: (list) {
            if (list.isEmpty) return Center(child: Text(T.noData.s, style: Txt.small));
            return ListView.builder(
              itemCount: list.length,
              itemBuilder: (_, i) {
                final m = list[i];
                final tone = m.qty >= 0 ? Tone.good : Tone.bad;
                return InkWell(
                  onTap: m.refType == 'sale' && m.refId != null ? () => context.go('/sales/${m.refId}') : null,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                    child: Row(children: [
                      Container(
                        width: 28,
                        height: 28,
                        decoration: BoxDecoration(color: tone.bg, borderRadius: BorderRadius.circular(8)),
                        child: Icon(m.qty >= 0 ? Icons.south_rounded : Icons.north_rounded, size: 15, color: tone.fg),
                      ),
                      const Gap(10),
                      Expanded(child: Cell2(tKey('r', m.kind), [friendlyDate(m.date), if (m.note != null) m.note!].join(' · '), Txt.body)),
                      Text('${m.qty >= 0 ? '+' : '−'}${qty(m.qty.abs())}', style: Txt.num.copyWith(color: tone.fg)),
                    ]),
                  ),
                );
              },
            );
          }),
        ),
      ]);
    });
  }

  Widget _kv(String k, String v, {bool big = false, Color? color}) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(k, style: Txt.tiny),
        const Gap(2),
        Text(v, style: big ? Txt.display(20, color: color ?? C.ink) : Txt.strong.copyWith(color: color)),
      ]);

  Future<void> _adjust(BuildContext context, WidgetRef ref, Product p) async {
    final qtyC = TextEditingController();
    final noteC = TextEditingController();
    var mode = 0; // 0 add, 1 remove, 2 set count
    var reason = 'adjust';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setD) {
        return AppDialog(
          title: T.adjustStock.s,
          icon: Icons.tune_rounded,
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(T.cancel.s)),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(T.save.s)),
          ],
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('${p.name} · ${T.stock.s}: ${qty(p.stock)} ${unitLabel(p.unit)}', style: Txt.small),
            const Gap(12),
            SegmentedButton<int>(
              showSelectedIcon: false,
              segments: [
                ButtonSegment(value: 0, label: Text(T.addStock.s), icon: const Icon(Icons.add_rounded)),
                ButtonSegment(value: 1, label: Text(T.removeStock.s), icon: const Icon(Icons.remove_rounded)),
                ButtonSegment(value: 2, label: Text(T.countStock.s), icon: const Icon(Icons.fact_check_outlined)),
              ],
              selected: {mode},
              onSelectionChanged: (s) => setD(() => mode = s.first),
            ),
            const Gap(14),
            NumField(controller: qtyC, label: mode == 2 ? T.countStock.s : T.qty.s, suffix: unitLabel(p.unit), autofocus: true),
            if (mode == 1) ...[
              const Gap(12),
              DropdownButtonFormField<String>(
                initialValue: reason,
                decoration: InputDecoration(labelText: T.reason.s),
                items: [
                  for (final r in ['adjust', 'damage', 'lost']) DropdownMenuItem(value: r, child: Text(tKey('r', r))),
                ],
                onChanged: (v) => setD(() => reason = v ?? 'adjust'),
              ),
            ],
            const Gap(12),
            TextIn(controller: noteC, label: T.noteOptional.s),
          ]),
        );
      }),
    );
    if (ok == true && context.mounted) {
      final biz = ref.read(bizProvider);
      final n = parseNum(qtyC.text);
      await guard(context, () async {
        if (mode == 2) {
          await biz.products.setStock(p.id, n, note: noteC.text.trim().isEmpty ? null : noteC.text.trim());
        } else {
          if (n <= 0) throw BizException('qty_positive');
          await biz.products.adjustStock(p.id, mode == 0 ? n : -n,
              kind: mode == 0 ? 'adjust' : reason, note: noteC.text.trim().isEmpty ? null : noteC.text.trim());
        }
      }, success: T.saved.s);
    }
    qtyC.dispose();
    noteC.dispose();
  }

  Future<void> _labels(BuildContext context, WidgetRef ref, Product p) async {
    final copies = TextEditingController(text: '24');
    var sheet = true;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AppDialog(
          title: T.printLabels.s,
          icon: Icons.qr_code_2_rounded,
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(T.cancel.s)),
            FilledButton.icon(onPressed: () => Navigator.pop(ctx, true), icon: const Icon(Icons.print_outlined, size: 18), label: Text(T.print.s)),
          ],
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (p.barcode == null || p.barcode!.isEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(isBangla ? 'এই পণ্যে বারকোড নেই — SKU বা আইডি দিয়ে লেবেল হবে।' : 'No barcode on this product — the SKU or ID will be used.',
                    style: Txt.small.copyWith(color: C.warn)),
              ),
            NumField(controller: copies, label: T.copies.s, decimal: false, autofocus: true),
            const Gap(12),
            SegmentedButton<bool>(
              showSelectedIcon: false,
              segments: [
                ButtonSegment(value: true, label: Text(isBangla ? 'A4 শিট (৩×৮)' : 'A4 sheet (3×8)')),
                ButtonSegment(value: false, label: Text(isBangla ? 'লেবেল প্রিন্টার ৫০×৩০ মিমি' : 'Label printer 50×30 mm')),
              ],
              selected: {sheet},
              onSelectionChanged: (s) => setD(() => sheet = s.first),
            ),
          ]),
        ),
      ),
    );
    if (ok == true && context.mounted) {
      final n = int.tryParse(copies.text) ?? 24;
      await guard(context, () => PrintService.printLabels(context, ref.read(bizProvider), p, copies: n.clamp(1, 500), sheet: sheet));
    }
    copies.dispose();
  }
}

// =============================================================== form

Future<void> showProductForm(BuildContext context, WidgetRef ref, {Product? product}) =>
    showDialog(context: context, builder: (_) => _ProductForm(product: product));

const _otherUnit = '__other__';

String _plainNum(double v) => v == v.roundToDouble() ? v.toInt().toString() : v.toString();

class _ProductForm extends ConsumerStatefulWidget {
  final Product? product;
  const _ProductForm({this.product});
  @override
  ConsumerState<_ProductForm> createState() => _ProductFormState();
}

class _ProductFormState extends ConsumerState<_ProductForm> {
  late final name = TextEditingController(text: widget.product?.name ?? '');
  late final sku = TextEditingController(text: widget.product?.sku ?? '');
  late final barcode = TextEditingController(text: widget.product?.barcode ?? '');
  late final cost = TextEditingController(text: _v(widget.product?.costPrice));
  late final price = TextEditingController(text: _v(widget.product?.salePrice));
  late final wholesale = TextEditingController(text: _v(widget.product?.wholesalePrice));
  late final stock = TextEditingController(text: widget.product == null ? '' : _plainNum(widget.product!.stock));
  late final low = TextEditingController(text: _v(widget.product?.lowStock) == '' ? '5' : _v(widget.product?.lowStock));
  late final desc = TextEditingController(text: widget.product?.description ?? '');
  late String unit = widget.product?.unit ?? 'pcs';
  late int? categoryId = widget.product?.categoryId;
  late bool track = widget.product?.trackStock ?? true;
  late String? imagePath = widget.product?.imagePath;
  late bool more = (widget.product?.wholesalePrice ?? 0) > 0 ||
      (widget.product?.sku?.isNotEmpty ?? false) ||
      (widget.product?.description?.isNotEmpty ?? false);
  int _unitRev = 0;
  bool saving = false;

  static String _v(double? d) => d == null || d == 0 ? '' : _plainNum(d);

  @override
  void dispose() {
    for (final c in [name, sku, barcode, cost, price, wholesale, stock, low, desc]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _pickImage() async {
    final f = await FilePicker.pickFile(type: FileType.image);
    if (f == null) return;
    final session = ref.read(sessionProvider);
    final dir = await BusinessStore.imagesDir(session.info.id);
    final target = p.join(dir.path, 'p_${DateTime.now().millisecondsSinceEpoch}${p.extension(f.name)}');
    // Android pickers may hand back a content:// link without a file path.
    if (f.path != null) {
      await File(f.path!).copy(target);
    } else {
      await File(target).writeAsBytes(await f.readAsBytes());
    }
    setState(() => imagePath = target);
  }

  Future<void> _pickUnit(String? v) async {
    if (v == null) return;
    if (v != _otherUnit) {
      setState(() => unit = v);
      return;
    }
    final c = TextEditingController();
    final custom = await showDialog<String>(
      context: context,
      builder: (ctx) => AppDialog(
        title: T.otherUnit.s,
        icon: Icons.straighten_rounded,
        width: 380,
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(T.cancel.s)),
          FilledButton(onPressed: () => Navigator.pop(ctx, c.text.trim()), child: Text(T.save.s)),
        ],
        child: TextIn(controller: c, label: T.customUnit.s, hint: 'gaj, roll, tola…', autofocus: true,
            onSubmitted: (_) => Navigator.pop(ctx, c.text.trim())),
      ),
    );
    c.dispose();
    if (!mounted) return;
    setState(() {
      if (custom != null && custom.isNotEmpty) {
        if (isNumericUnit(custom)) {
          toast(context, T.e_unit_invalid.s, error: true);
        } else {
          unit = custom;
        }
      }
      _unitRev++; // reset the dropdown if "Other" was cancelled
    });
  }

  Future<void> _save({bool another = false}) async {
    if (saving) return;
    final biz = ref.read(bizProvider);
    final editing = widget.product != null;
    final input = ProductInput(
      name: name.text,
      sku: sku.text,
      barcode: barcode.text,
      categoryId: categoryId,
      unit: unit,
      costPrice: parseNum(cost.text),
      salePrice: parseNum(price.text),
      wholesalePrice: parseNum(wholesale.text),
      lowStock: parseNum(low.text),
      trackStock: track,
      description: desc.text,
      imagePath: imagePath,
    );
    final router = GoRouter.of(context);
    setState(() => saving = true);
    var newId = 0;
    final ok = await guard(context, () async {
      if (!editing) {
        newId = await biz.products.create(input, openingStock: track ? parseNum(stock.text) : 0);
      } else {
        final pr = widget.product!;
        await biz.products.update(pr.id, input);
        // Changing the stock here is recorded as a stock count, never silently.
        final newStock = parseNum(stock.text, pr.stock);
        if (track && (newStock - pr.stock).abs() > 0.0005) {
          await biz.products.setStock(pr.id, newStock, note: T.stockEdited.s);
        }
      }
    }, success: T.saved.s);
    if (!mounted) return;
    setState(() => saving = false);
    if (!ok) return;
    if (another) {
      setState(() {
        for (final c in [name, sku, barcode, cost, price, wholesale, stock, desc]) {
          c.clear();
        }
        imagePath = null;
      });
    } else {
      Navigator.pop(context);
      if (newId > 0) router.go('/products/$newId');
    }
  }

  @override
  Widget build(BuildContext context) {
    final cats = ref.watch(_cats).value ?? const <ProductCategory>[];
    final editing = widget.product != null;
    final c = parseNum(cost.text), s = parseNum(price.text);
    final units = [...unitSuggestions, if (!unitSuggestions.contains(unit)) unit];

    final photo = InkWell(
      onTap: _pickImage,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        width: 84,
        height: 84,
        decoration: BoxDecoration(color: C.paper, borderRadius: BorderRadius.circular(14), border: Border.all(color: C.line)),
        clipBehavior: Clip.antiAlias,
        child: imagePath != null && File(imagePath!).existsSync()
            ? Image.file(File(imagePath!), fit: BoxFit.cover)
            : Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                const Icon(Icons.add_photo_alternate_outlined, color: C.ink3),
                const Gap(4),
                Text(T.productImage.s, style: Txt.tiny),
              ]),
      ),
    );
    final category = Row(children: [
      Expanded(
        child: DropdownButtonFormField<int?>(
          initialValue: cats.any((x) => x.id == categoryId) ? categoryId : null,
          isExpanded: true,
          decoration: InputDecoration(labelText: T.category.s),
          items: [
            DropdownMenuItem(value: null, child: Text(T.none.s)),
            for (final cat in cats) DropdownMenuItem(value: cat.id, child: Text(cat.name, overflow: TextOverflow.ellipsis)),
          ],
          onChanged: (v) => setState(() => categoryId = v),
        ),
      ),
      IconButton(
        tooltip: T.addCategory.s,
        onPressed: () => _addCategory(context, ref),
        icon: const Icon(Icons.add_circle_outline_rounded, color: C.brand),
      ),
    ]);
    final unitField = DropdownButtonFormField<String>(
      key: ValueKey('unit-$unit-$_unitRev'),
      initialValue: unit,
      isExpanded: true,
      decoration: InputDecoration(labelText: T.unitPick.s),
      items: [
        for (final u in units) DropdownMenuItem(value: u, child: Text(unitLabel(u))),
        DropdownMenuItem(value: _otherUnit, child: Text(T.otherUnit.s, style: const TextStyle(color: C.brand))),
      ],
      onChanged: _pickUnit,
    );
    final stockField = NumField(
      controller: stock,
      label: '${T.stockNow.s} (${unitLabel(unit)})',
      helper: T.stockNowHint.s,
      onSubmitted: (_) => _save(),
    );
    final barcodeField = TextIn(
      controller: barcode,
      label: T.barcode.s,
      icon: Icons.qr_code_rounded,
      suffix: Row(mainAxisSize: MainAxisSize.min, children: [
        ScanButton(onCode: (code) => setState(() => barcode.text = code)),
        TextButton(onPressed: () => setState(() => barcode.text = generateBarcode()), child: Text(T.generate.s)),
      ]),
    );

    return AppDialog(
      title: editing ? T.editProduct.s : T.addProduct.s,
      icon: Icons.inventory_2_outlined,
      width: 640,
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(T.cancel.s)),
        if (!editing)
          OutlinedButton(onPressed: saving ? null : () => _save(another: true), child: Text(isBangla ? 'সেভ ও আরেকটি' : 'Save & add another')),
        FilledButton(onPressed: saving ? null : _save, child: Text(T.save.s)),
      ],
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        LayoutBuilder(builder: (context, box) {
          final fields = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            TextIn(controller: name, label: T.productName.s, autofocus: true, onSubmitted: (_) => _save()),
            const Gap(12),
            category,
          ]);
          if (box.maxWidth < 480) {
            return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [photo, const Gap(12), fields]);
          }
          return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [photo, const Gap(14), Expanded(child: fields)]);
        }),
        const Gap(14),
        FieldRow(minFieldWidth: 150, children: [
          NumField(
            controller: price,
            label: T.salePrice.s,
            prefix: '৳ ',
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) => _save(),
          ),
          NumField(controller: cost, label: T.costPrice.s, prefix: '৳ ', onChanged: (_) => setState(() {})),
          if (track) stockField,
        ]),
        if (s > 0 && c > 0)
          Padding(
            padding: const EdgeInsets.only(top: 6, left: 4),
            child: Text('${T.margin.s} ${pct((s - c) / s * 100)} · ${T.profit.s} ${money(s - c)}',
                style: Txt.tiny.copyWith(color: s >= c ? C.inGreen : C.outRed)),
          ),
        const Gap(12),
        FieldRow(minFieldWidth: 190, flex: const [2, 3], children: [unitField, barcodeField]),
        const Gap(6),
        InkWell(
          onTap: () => setState(() => more = !more),
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(children: [
              Icon(more ? Icons.expand_less_rounded : Icons.expand_more_rounded, color: C.brand),
              const Gap(6),
              Text(T.moreDetails.s, style: Txt.strong.copyWith(color: C.brand)),
              const Gap(8),
              if (!more) Expanded(child: Text(T.moreDetailsHint.s, style: Txt.tiny, overflow: TextOverflow.ellipsis)),
            ]),
          ),
        ),
        if (more) ...[
          FieldRow(minFieldWidth: 170, children: [
            NumField(controller: wholesale, label: '${T.wholesale.s} (${T.optional.s})', prefix: '৳ '),
            TextIn(controller: sku, label: T.sku.s),
          ]),
          const Gap(12),
          if (track) NumField(controller: low, label: '${T.lowStockAlert.s} (${unitLabel(unit)})'),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: track,
            onChanged: (v) => setState(() => track = v),
            title: Text(T.trackStock.s, style: Txt.strong),
            subtitle: Text(T.trackStockHint.s, style: Txt.tiny),
          ),
          TextIn(controller: desc, label: '${T.description.s} (${T.optional.s})', maxLines: 3),
        ],
      ]),
    );
  }
}
