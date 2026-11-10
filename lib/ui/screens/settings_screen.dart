import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:path/path.dart' as p;
import 'package:printing/printing.dart' show Printer;
import 'package:share_plus/share_plus.dart';

import '../../core/format.dart';
import '../../core/i18n.dart';
import '../../core/theme.dart';
import '../../core/util.dart';
import '../../couriers/registry.dart';
import '../../data/biz.dart';
import '../../data/business_store.dart';
import '../../data/seed.dart';
import '../../services/messaging.dart';
import '../../services/print_service.dart';
import '../../services/templates.dart';
import '../../state/app_state.dart';
import '../widgets/common.dart';
import 'cashbox_screen.dart' show showAccountDialog;
import 'settings_cloud.dart';
import 'settings_website.dart';
import 'expenses_screen.dart' show expenseCatsProvider;

final _cats = StreamProvider.autoDispose((ref) => ref.watch(bizProvider).products.watchCategories());

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});
  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  int section = 0;

  /// Narrow screens: list of sections first, then one section full-screen.
  bool open = false;

  @override
  Widget build(BuildContext context) {
    final owner = ref.watch(actorProvider).isOwner;
    final sections = <(IconData, String, Widget Function(Map<String, String>))>[
      (Icons.storefront_outlined, T.businessProfile.s, (s) => _BusinessSection(s)),
      (Icons.receipt_long_outlined, '${T.invoiceSettings.s} · ${T.printerSetup.s}', (s) => _InvoiceSection(s)),
      (Icons.category_outlined, '${T.paymentAccounts.s} · ${T.categories.s}', (s) => const _ListsSection()),
      (Icons.local_shipping_outlined, T.onlineSettings.s, (s) => _CourierSection(s)),
      (Icons.language_rounded, T.webTitle.s, (s) => const WebsiteSettings()),
      (Icons.sms_outlined, '${T.smsGateway.s} · ${T.messageTemplates.s}', (s) => _SmsSection(s)),
      // PIN, staff, restore and deleting the business stay with the owner.
      if (owner) (Icons.cloud_outlined, T.cloudTitle.s, (s) => const CloudSettings()),
      if (owner) (Icons.lock_outline_rounded, '${T.security.s} · ${T.staff.s}', (s) => _SecuritySection(s)),
      if (owner) (Icons.backup_outlined, T.backup.s, (s) => _BackupSection(s)),
      (Icons.info_outline_rounded, T.about.s, (s) => const _AboutSection()),
    ];
    if (section >= sections.length) section = 0;
    final settings = ref.watch(settingsProvider);
    final compact = context.isCompact;
    final nav = Container(
        width: compact ? null : 270,
        decoration: const BoxDecoration(border: Border(right: BorderSide(color: C.line))),
        child: ListView(padding: const EdgeInsets.fromLTRB(14, 22, 14, 14), children: [
          Padding(padding: const EdgeInsets.fromLTRB(10, 0, 10, 14), child: Text(T.settings.s, style: Txt.display(26))),
          for (var i = 0; i < sections.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Material(
                color: section == i ? C.brandSoft : Colors.transparent,
                borderRadius: BorderRadius.circular(10),
                child: ListTile(
                  dense: true,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  leading: Icon(sections[i].$1, size: 20, color: section == i ? C.brand : C.ink2),
                  title: Text(sections[i].$2,
                      style: Txt.body.copyWith(fontWeight: section == i ? FontWeight.w700 : FontWeight.w500, color: section == i ? C.brand : C.ink)),
                  onTap: () => setState(() {
                    section = i;
                    open = true;
                  }),
                ),
              ),
            ),
        ]),
      );
    final Widget body = AsyncView(settings, builder: (s) {
          return ListView(padding: EdgeInsets.fromLTRB(context.isPhone ? 12 : 32, context.isPhone ? 8 : 26, context.isPhone ? 12 : 32, 40), children: [
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 760),
                child: KeyedSubtree(
                  key: ValueKey(section),
                  child: sections[section].$3(s),
                ),
              ),
            ),
          ]);
        });
    if (compact) {
      if (!open) return nav;
      return PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) setState(() => open = false);
        },
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 6, 4, 0),
            child: Row(children: [
              IconButton(onPressed: () => setState(() => open = false), icon: const Icon(Icons.arrow_back_rounded)),
              Expanded(child: Text(sections[section].$2, style: Txt.strong.copyWith(fontSize: 16), overflow: TextOverflow.ellipsis)),
            ]),
          ),
          Expanded(child: body),
        ]),
      );
    }
    return Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      nav,
      Expanded(child: body),
    ]);
  }
}

Widget _sectionTitle(String t, [String? sub]) => Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(t, style: Txt.display(22)),
        if (sub != null) ...[const Gap(4), Text(sub, style: Txt.small)],
      ]),
    );

// ---------------------------------------------------------------- business

class _BusinessSection extends ConsumerStatefulWidget {
  final Map<String, String> s;
  const _BusinessSection(this.s);
  @override
  ConsumerState<_BusinessSection> createState() => _BusinessSectionState();
}

class _BusinessSectionState extends ConsumerState<_BusinessSection> {
  late final name = TextEditingController(text: widget.s.str(K.businessName));
  late final phone = TextEditingController(text: widget.s.str(K.phone));
  late final address = TextEditingController(text: widget.s.str(K.address));
  late final email = TextEditingController(text: widget.s.str(K.email));
  late String type = widget.s.str(K.businessType, 'other');
  late String logo = widget.s.str(K.logoPath);

  @override
  void dispose() {
    for (final c in [name, phone, address, email]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _pickLogo() async {
    final f = await FilePicker.pickFile(type: FileType.image);
    if (f == null) return;
    final dir = await BusinessStore.folder(ref.read(sessionProvider).info.id);
    final target = p.join(dir.path, 'logo${p.extension(f.name)}');
    if (f.path != null) {
      await File(f.path!).copy(target);
    } else {
      await File(target).writeAsBytes(await f.readAsBytes());
    }
    imageCache.clear();
    setState(() => logo = target);
  }

  Future<void> _save() async {
    final biz = ref.read(bizProvider);
    await guard(context, () async {
      if (name.text.trim().isEmpty) throw BizException('name_required');
      await biz.settings.setMany({
        K.businessName: name.text.trim(),
        K.phone: phone.text.trim(),
        K.address: address.text.trim(),
        K.email: email.text.trim(),
        K.businessType: type,
        K.logoPath: logo,
      });
      await ref.read(appProvider.notifier).renameCurrent(name.text, type);
    }, success: T.saved.s);
  }

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _sectionTitle(T.businessProfile.s),
      Panel(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            InkWell(
              onTap: _pickLogo,
              borderRadius: BorderRadius.circular(14),
              child: Container(
                width: 96,
                height: 96,
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(color: C.paper, borderRadius: BorderRadius.circular(14), border: Border.all(color: C.line)),
                child: logo.isNotEmpty && File(logo).existsSync()
                    ? Image.file(File(logo), fit: BoxFit.contain)
                    : Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                        const Icon(Icons.add_photo_alternate_outlined, color: C.ink3),
                        Text(T.logo.s, style: Txt.tiny),
                      ]),
              ),
            ),
            const Gap(16),
            Expanded(
              child: Column(children: [
                TextIn(controller: name, label: T.businessName.s),
                const Gap(12),
                DropdownButtonFormField<String>(
                  initialValue: businessTypes.any((t) => t.id == type) ? type : 'other',
                  decoration: InputDecoration(labelText: T.businessType.s),
                  items: [for (final t in businessTypes) DropdownMenuItem(value: t.id, child: Text('${t.icon}  ${isBangla ? t.bn : t.en}'))],
                  onChanged: (v) => setState(() => type = v ?? type),
                ),
              ]),
            ),
          ]),
          const Gap(12),
          FieldRow(children: [TextIn(controller: phone, label: T.phone.s, icon: Icons.phone_outlined), TextIn(controller: email, label: T.email.s, icon: Icons.alternate_email_rounded)]),
          const Gap(12),
          TextIn(controller: address, label: T.address.s, icon: Icons.place_outlined),
          const Gap(16),
          Align(alignment: Alignment.centerRight, child: BusyButton(label: T.save.s, icon: Icons.check_rounded, onPressed: _save)),
        ]),
      ),
    ]);
  }
}

// ---------------------------------------------------------------- invoice

class _InvoiceSection extends ConsumerStatefulWidget {
  final Map<String, String> s;
  const _InvoiceSection(this.s);
  @override
  ConsumerState<_InvoiceSection> createState() => _InvoiceSectionState();
}

class _InvoiceSectionState extends ConsumerState<_InvoiceSection> {
  late final prefix = TextEditingController(text: widget.s.str(K.invoicePrefix, 'INV-'));
  late final footer = TextEditingController(text: widget.s.str(K.receiptFooter));
  late final vat = TextEditingController(text: widget.s.str(K.vatPercent));
  late String paper = widget.s.str(K.paperSize, '80');
  late bool autoPrint = widget.s.flag(K.autoPrint);
  late bool negative = widget.s.flag(K.allowNegativeStock, fallback: true);
  late int? account = int.tryParse(widget.s.str(K.defaultAccount));

  @override
  void dispose() {
    prefix.dispose();
    footer.dispose();
    vat.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final biz = ref.read(bizProvider);
    await guard(context, () async {
      await biz.settings.setMany({
        K.invoicePrefix: prefix.text.trim(),
        K.receiptFooter: footer.text.trim(),
        K.vatPercent: '${parseNum(vat.text)}',
        K.paperSize: paper,
        K.autoPrint: autoPrint ? '1' : '0',
        K.allowNegativeStock: negative ? '1' : '0',
        K.defaultAccount: account?.toString() ?? '',
      });
    }, success: T.saved.s);
  }

  @override
  Widget build(BuildContext context) {
    final next = widget.s.str(K.nextInvoice, '1001');
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _sectionTitle(T.invoiceSettings.s),
      Panel(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          FieldRow(children: [TextIn(controller: prefix, label: T.invoicePrefix.s, onChanged: (_) => setState(() {})), InputDecorator(decoration: InputDecoration(labelText: T.invoiceNo.s), child: Text('${prefix.text}$next', style: Txt.strong))]),
          const Gap(12),
          TextIn(controller: footer, label: T.receiptFooter.s, maxLines: 2),
          const Gap(16),
          Text(T.paperSize.s, style: Txt.label),
          const Gap(8),
          SegmentedButton<String>(
            showSelectedIcon: false,
            segments: [
              ButtonSegment(value: '58', label: Text(T.paper58.s)),
              ButtonSegment(value: '80', label: Text(T.paper80.s)),
              ButtonSegment(value: 'a4', label: Text(T.paperA4.s)),
            ],
            selected: {paper},
            onSelectionChanged: (v) => setState(() => paper = v.first),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: autoPrint,
            onChanged: (v) => setState(() => autoPrint = v),
            title: Text(T.autoPrint.s, style: Txt.strong),
          ),
          SizedBox(width: 220, child: NumField(controller: vat, label: T.defaultVat.s, suffix: '%')),
          const Gap(16),
          Text('${T.paymentMethod.s} (${T.newSale.s})', style: Txt.label),
          const Gap(8),
          AccountChips(value: account, onChanged: (v) => setState(() => account = v)),
        ]),
      ),
      if (PrintService.canPickPrinter) ...[
        const Gap(16),
        const _PrinterPanel(),
      ],
      const Gap(16),
      Panel(
        title: T.stockSettings.s,
        child: SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: negative,
          onChanged: (v) => setState(() => negative = v),
          title: Text(T.allowNegative.s, style: Txt.strong),
          subtitle: Text(T.allowNegativeHint.s, style: Txt.tiny),
        ),
      ),
      const Gap(16),
      Align(alignment: Alignment.centerRight, child: BusyButton(label: T.save.s, icon: Icons.check_rounded, onPressed: _save)),
    ]);
  }
}

/// Pick the receipt printer for this computer (stored on the device, not in the shop's data).
class _PrinterPanel extends ConsumerStatefulWidget {
  const _PrinterPanel();
  @override
  ConsumerState<_PrinterPanel> createState() => _PrinterPanelState();
}

class _PrinterPanelState extends ConsumerState<_PrinterPanel> {
  List<Printer>? printers;
  String? selected;

  @override
  void initState() {
    super.initState();
    Future.microtask(() async {
      var list = const <Printer>[];
      Printer? saved;
      try {
        list = await PrintService.printers();
        saved = await PrintService.savedPrinter();
      } catch (_) {
        // No printer service (or no saved choice): show the empty list.
      }
      if (mounted) {
        setState(() {
          printers = list;
          selected = saved?.url;
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final list = printers;
    final urls = {for (final p in list ?? const <Printer>[]) p.url};
    return Panel(
      title: T.defaultPrinter.s,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(T.defaultPrinterHint.s, style: Txt.small),
        const Gap(12),
        if (list == null)
          const LinearProgressIndicator()
        else
          AdaptiveRow(children: [
            Expanded(
              child: DropdownButtonFormField<String>(
                initialValue: urls.contains(selected) ? selected : '',
                isExpanded: true,
                decoration: InputDecoration(labelText: T.printerSetup.s),
                items: [
                  DropdownMenuItem(value: '', child: Text(T.askEveryTime.s)),
                  for (final p in list)
                    DropdownMenuItem(value: p.url, child: Text(p.isDefault ? '${p.name} ★' : p.name, overflow: TextOverflow.ellipsis)),
                ],
                onChanged: (v) async {
                  final printer = (v == null || v.isEmpty) ? null : list.firstWhere((p) => p.url == v);
                  await PrintService.savePrinter(printer);
                  setState(() => selected = printer?.url);
                },
              ),
            ),
            const Gap(12),
            OutlinedButton.icon(
              onPressed: () async {
                var direct = false;
                final ok = await guard(context, () async {
                  direct = await PrintService.printTest(context, ref.read(settingsProvider).value ?? const {});
                });
                if (ok && direct && context.mounted) toast(context, T.printed.s);
              },
              icon: const Icon(Icons.print_outlined, size: 18),
              label: Text(T.testPrint.s),
            ),
          ]),
        if (list != null && list.isEmpty) ...[
          const Gap(6),
          Text(T.noPrinters.s, style: Txt.tiny),
        ],
      ]),
    );
  }
}

// ---------------------------------------------------------------- lists

class _ListsSection extends ConsumerWidget {
  const _ListsSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final accounts = ref.watch(accountsProvider).value ?? const <Account>[];
    final expCats = ref.watch(expenseCatsProvider).value ?? const <ExpenseCategory>[];
    final cats = ref.watch(_cats).value ?? const <ProductCategory>[];
    final biz = ref.watch(bizProvider);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _sectionTitle(T.paymentAccounts.s),
      Panel(
        trailing: TextButton.icon(onPressed: () => showAccountDialog(context, ref), icon: const Icon(Icons.add, size: 18), label: Text(T.addAccount.s)),
        title: T.accounts.s,
        child: Column(children: [
          for (final a in accounts)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(accountIcon(a.kind), color: C.brand),
              title: Text(a.name, style: Txt.strong),
              subtitle: Text('${tKey('ak', a.kind)} · ${T.openingAmount.s}: ${money(a.opening)}', style: Txt.tiny),
              trailing: IconButton(onPressed: () => showAccountDialog(context, ref, account: a), icon: const Icon(Icons.edit_outlined, size: 18)),
            ),
        ]),
      ),
      const Gap(16),
      Panel(
        title: T.categories.s,
        trailing: TextButton.icon(
          onPressed: () async {
            final name = await _ask(context, T.addCategory.s);
            if (name != null && context.mounted) await guard(context, () => biz.products.addCategory(name));
          },
          icon: const Icon(Icons.add, size: 18),
          label: Text(T.add.s),
        ),
        child: Wrap(spacing: 8, runSpacing: 8, children: [
          for (final c in cats)
            InputChip(
              label: Text(c.name),
              onPressed: () async {
                final name = await _ask(context, T.edit.s, initial: c.name);
                if (name != null && context.mounted) await guard(context, () => biz.products.renameCategory(c.id, name));
              },
              onDeleted: () => guard(context, () => biz.products.deleteCategory(c.id)),
            ),
        ]),
      ),
      const Gap(16),
      Panel(
        title: T.expenseTypes.s,
        trailing: TextButton.icon(
          onPressed: () async {
            final name = await _ask(context, T.expenseCategory.s);
            if (name != null && context.mounted) await guard(context, () => biz.expenses.ensureCategory(name));
          },
          icon: const Icon(Icons.add, size: 18),
          label: Text(T.add.s),
        ),
        child: Wrap(spacing: 8, runSpacing: 8, children: [
          for (final c in expCats)
            InputChip(
              label: Text(c.name),
              onDeleted: c.name == 'Courier charge' || c.name == 'Courier return charge'
                  ? null
                  : () => guard(context, () => biz.expenses.deleteCategory(c.id)),
            ),
        ]),
      ),
    ]);
  }
}

Future<String?> _ask(BuildContext context, String title, {String initial = ''}) async {
  final c = TextEditingController(text: initial);
  final r = await showDialog<String>(
    context: context,
    builder: (ctx) => AppDialog(
      title: title,
      width: 400,
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: Text(T.cancel.s)),
        FilledButton(onPressed: () => Navigator.pop(ctx, c.text.trim()), child: Text(T.save.s)),
      ],
      child: TextIn(controller: c, label: T.name.s, autofocus: true, onSubmitted: (_) => Navigator.pop(ctx, c.text.trim())),
    ),
  );
  c.dispose();
  return (r == null || r.isEmpty) ? null : r;
}

// ---------------------------------------------------------------- couriers

class _CourierSection extends ConsumerStatefulWidget {
  final Map<String, String> s;
  const _CourierSection(this.s);
  @override
  ConsumerState<_CourierSection> createState() => _CourierSectionState();
}

class _CourierSectionState extends ConsumerState<_CourierSection> {
  late Map<String, dynamic> cfg = widget.s.json(K.courierConfig);
  late bool online = widget.s.flag(K.onlineEnabled);
  final ctrls = <String, TextEditingController>{};
  final testing = <String>{};

  TextEditingController c(String section, String key) => ctrls.putIfAbsent('$section.$key', () {
        final sec = (cfg[section] as Map?) ?? const {};
        final v = sec[key];
        return TextEditingController(text: v == null || v == 0 ? '' : '$v');
      });

  TextEditingController top(String key, double fallback) => ctrls.putIfAbsent(key, () {
        final v = cfg[key] as num? ?? fallback;
        return TextEditingController(text: v == v.roundToDouble() ? '${v.toInt()}' : '$v');
      });

  @override
  void dispose() {
    for (final c in ctrls.values) {
      c.dispose();
    }
    super.dispose();
  }

  Map<String, dynamic> _collect() {
    Map<String, dynamic> sec(String id, List<String> strings, List<String> ints) {
      final old = Map<String, dynamic>.from((cfg[id] as Map?) ?? const {});
      for (final k in strings) {
        old[k] = c(id, k).text.trim();
      }
      for (final k in ints) {
        old[k] = int.tryParse(toLatinDigits(c(id, k).text.trim())) ?? 0;
      }
      return old;
    }

    return {
      ...cfg,
      'deliveryFee': parseNum(top('deliveryFee', 60).text),
      'returnFee': parseNum(top('returnFee', 0).text),
      'steadfast': sec('steadfast', ['apiKey', 'secretKey', 'baseUrl'], []),
      'pathao': sec('pathao', ['clientId', 'clientSecret', 'username', 'password'], ['storeId', 'cityId', 'zoneId']),
      'redx': sec('redx', ['token', 'areaName'], ['areaId']),
    };
  }

  Future<void> _save() async {
    final biz = ref.read(bizProvider);
    await guard(context, () async {
      cfg = _collect();
      await biz.settings.setJson(K.courierConfig, cfg);
      await biz.settings.setFlag(K.onlineEnabled, online);
    }, success: T.saved.s);
  }

  Future<void> _test(String id) async {
    setState(() => testing.add(id));
    try {
      final msg = await CourierConfig(_collect()).adapter(id).testConnection();
      if (mounted) toast(context, '${courierNames[id]}: $msg');
    } catch (e) {
      if (mounted) toast(context, '${courierNames[id]}: ${errorText(e)}', error: true);
    } finally {
      if (mounted) setState(() => testing.remove(id));
    }
  }

  Widget _secPanel(String id, String subtitle, List<Widget> fields, {bool sandbox = false}) {
    final sec = Map<String, dynamic>.from((cfg[id] as Map?) ?? const {});
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Panel(
        title: courierNames[id],
        trailing: OutlinedButton.icon(
          onPressed: testing.contains(id) ? null : () => _test(id),
          icon: testing.contains(id)
              ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.wifi_tethering_rounded, size: 17),
          label: Text(T.testConnection.s),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(subtitle, style: Txt.tiny),
          const Gap(12),
          ...fields,
          if (sandbox)
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: sec['sandbox'] == true,
              onChanged: (v) => setState(() => cfg = {
                    ...cfg,
                    id: {...sec, 'sandbox': v}
                  }),
              title: Text(T.sandbox.s, style: Txt.body),
            ),
        ]),
      ),
    );
  }

  Widget _two(Widget a, Widget b) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: FieldRow(children: [a, b]),
      );

  @override
  Widget build(BuildContext context) {
    final testMode = cfg['testMode'] == true;
    final def = (cfg['default'] as String?) ?? 'steadfast';
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _sectionTitle(T.onlineSettings.s, T.enableOnlineHint.s),
      Panel(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: online,
            onChanged: (v) => setState(() => online = v),
            title: Text(T.enableOnline.s, style: Txt.strong),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: testMode,
            onChanged: (v) => setState(() => cfg = {...cfg, 'testMode': v}),
            title: Text(T.testMode.s, style: Txt.strong),
            subtitle: Text(T.testModeOn.s, style: Txt.tiny),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: cfg['autoApply'] != false,
            onChanged: (v) => setState(() => cfg = {...cfg, 'autoApply': v}),
            title: Text(T.autoSettle.s, style: Txt.strong),
          ),
          const Gap(8),
          Text(T.defaultCourier.s, style: Txt.label),
          const Gap(8),
          Wrap(spacing: 8, children: [
            for (final id in courierIds)
              ChoiceChip(label: Text(courierNames[id]!), selected: def == id, onSelected: (_) => setState(() => cfg = {...cfg, 'default': id})),
          ]),
          const Gap(14),
          _two(
            NumField(controller: top('deliveryFee', 60), label: T.defaultDeliveryFee.s, prefix: '৳ '),
            NumField(controller: top('returnFee', 0), label: T.defaultReturnFee.s, prefix: '৳ '),
          ),
        ]),
      ),
      _secPanel('steadfast', 'portal.packzy.com → API (Api-Key / Secret-Key). ${isBangla ? 'কাস্টমারের ডেলিভারি রেকর্ড চেক এখান থেকেই হয়।' : 'Also powers the customer delivery-record check.'}', [
        _two(TextIn(controller: c('steadfast', 'apiKey'), label: T.apiKey.s),
            TextIn(controller: c('steadfast', 'secretKey'), label: T.secretKey.s, obscure: true)),
        TextIn(controller: c('steadfast', 'baseUrl'), label: T.baseUrlAdv.s, hint: 'https://portal.packzy.com/api/v1'),
      ]),
      _secPanel('pathao', 'merchant.pathao.com → Developers API', [
        _two(TextIn(controller: c('pathao', 'clientId'), label: T.clientId.s),
            TextIn(controller: c('pathao', 'clientSecret'), label: T.clientSecret.s, obscure: true)),
        _two(TextIn(controller: c('pathao', 'username'), label: T.merchantEmail.s),
            TextIn(controller: c('pathao', 'password'), label: T.password.s, obscure: true)),
        FieldRow(children: [NumField(controller: c('pathao', 'storeId'), label: T.storeId.s, decimal: false), NumField(controller: c('pathao', 'cityId'), label: T.defaultCityId.s, decimal: false), NumField(controller: c('pathao', 'zoneId'), label: T.defaultZoneId.s, decimal: false)]),
      ], sandbox: true),
      _secPanel('redx', 'redx.com.bd → Developer API', [
        TextIn(controller: c('redx', 'token'), label: T.token.s, obscure: true),
        const Gap(12),
        _two(NumField(controller: c('redx', 'areaId'), label: T.defaultAreaId.s, decimal: false),
            TextIn(controller: c('redx', 'areaName'), label: T.defaultAreaName.s)),
      ], sandbox: true),
      const Gap(16),
      Align(alignment: Alignment.centerRight, child: BusyButton(label: T.save.s, icon: Icons.check_rounded, onPressed: _save)),
    ]);
  }
}

// ---------------------------------------------------------------- sms

class _SmsSection extends ConsumerStatefulWidget {
  final Map<String, String> s;
  const _SmsSection(this.s);
  @override
  ConsumerState<_SmsSection> createState() => _SmsSectionState();
}

class _SmsSectionState extends ConsumerState<_SmsSection> {
  late final cfg = widget.s.json(K.smsConfig);
  late final url = TextEditingController(text: (cfg['url'] as String?) ?? '');
  late bool prefix88 = cfg['prefix88'] == true;
  final testPhone = TextEditingController();

  @override
  void dispose() {
    url.dispose();
    testPhone.dispose();
    super.dispose();
  }

  Future<void> _save() => guard(context, () => ref.read(bizProvider).settings.setJson(K.smsConfig, {'url': url.text.trim(), 'prefix88': prefix88}),
      success: T.saved.s);

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _sectionTitle(T.smsGateway.s, T.smsHint.s),
      Panel(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          TextIn(controller: url, label: T.smsUrl.s, maxLines: 3,
              hint: 'http://bulksmsbd.net/api/smsapi?api_key=KEY&type=text&number={number}&senderid=ID&message={message}'),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: prefix88,
            onChanged: (v) => setState(() => prefix88 = v),
            title: Text(isBangla ? 'নম্বরের আগে ৮৮ যোগ করুন (৮৮০১...)' : 'Send numbers as 8801… (with 88)', style: Txt.body),
          ),
          const Gap(8),
          Row(children: [
            Expanded(child: TextIn(controller: testPhone, label: '${T.phone.s} (test)', keyboard: TextInputType.phone)),
            const Gap(12),
            OutlinedButton.icon(
              onPressed: () async {
                await _save();
                if (!context.mounted) return;
                await guard(context, () => Messaging.sms(ref.read(bizProvider), testPhone.text, 'BizKhata test SMS ✓'), success: T.smsSent.s);
              },
              icon: const Icon(Icons.send_rounded, size: 17),
              label: Text(isBangla ? 'টেস্ট পাঠান' : 'Send test'),
            ),
          ]),
          const Gap(16),
          Align(alignment: Alignment.centerRight, child: BusyButton(label: T.save.s, icon: Icons.check_rounded, onPressed: _save)),
        ]),
      ),
      const Gap(16),
      _TemplatesPanel(s: widget.s),
    ]);
  }
}

class _TemplatesPanel extends ConsumerStatefulWidget {
  final Map<String, String> s;
  const _TemplatesPanel({required this.s});
  @override
  ConsumerState<_TemplatesPanel> createState() => _TemplatesPanelState();
}

class _TemplatesPanelState extends ConsumerState<_TemplatesPanel> {
  late final payment = TextEditingController(text: widget.s.str(K.paymentNumbers));
  late final texts = {for (final k in MsgKind.values) k: TextEditingController(text: templateText(widget.s, k))};
  late bool autoSms = widget.s.flag(K.autoSms);
  MsgKind open = MsgKind.invoice;

  @override
  void dispose() {
    payment.dispose();
    for (final c in texts.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    final biz = ref.read(bizProvider);
    await guard(context, () async {
      // Only store what differs from the default, so language changes still apply to the rest.
      final custom = <String, dynamic>{
        for (final k in MsgKind.values)
          if (texts[k]!.text.trim().isNotEmpty && texts[k]!.text.trim() != defaultTemplate(k).trim()) k.name: texts[k]!.text.trim(),
      };
      await biz.settings.setMany({
        K.paymentNumbers: payment.text.trim(),
        K.autoSms: autoSms ? '1' : '0',
      });
      await biz.settings.setJson(K.templates, custom);
    }, success: T.saved.s);
  }

  @override
  Widget build(BuildContext context) {
    final hasGateway = widget.s.json(K.smsConfig)['url'].toString().contains('{number}');
    return Panel(
      title: T.messageTemplates.s,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(T.messageTemplatesHint.s, style: Txt.small),
        const Gap(14),
        TextIn(controller: payment, label: T.paymentNumbers.s, hint: T.paymentNumbersHint.s, maxLines: 2),
        const Gap(14),
        Wrap(spacing: 6, runSpacing: 6, children: [
          for (final k in MsgKind.values)
            ChoiceChip(label: Text(tKey('tpl', k.name)), selected: open == k, onSelected: (_) => setState(() => open = k)),
        ]),
        const Gap(10),
        TextField(
          key: ValueKey('tpl-${open.name}'),
          controller: texts[open],
          minLines: 4,
          maxLines: 8,
          decoration: InputDecoration(labelText: tKey('tpl', open.name), alignLabelWithHint: true),
        ),
        const Gap(6),
        Row(children: [
          Expanded(
            child: Wrap(spacing: 4, runSpacing: 4, children: [
              Text('${T.tplTags.s}: ', style: Txt.tiny),
              for (final tag in templateTags[open]!)
                InkWell(
                  onTap: () {
                    final c = texts[open]!;
                    final sel = c.selection;
                    final at = sel.isValid ? sel.start : c.text.length;
                    c.text = c.text.replaceRange(at, sel.isValid ? sel.end : at, tag);
                    c.selection = TextSelection.collapsed(offset: at + tag.length);
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(color: C.paper, borderRadius: BorderRadius.circular(6), border: Border.all(color: C.line)),
                    child: Text(tag, style: Txt.tiny.copyWith(color: C.brand, fontWeight: FontWeight.w600)),
                  ),
                ),
            ]),
          ),
          TextButton(
            onPressed: () => setState(() => texts[open]!.text = defaultTemplate(open)),
            child: Text(T.resetDefault.s),
          ),
        ]),
        const Gap(8),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: autoSms,
          onChanged: hasGateway || autoSms ? (v) => setState(() => autoSms = v) : null,
          title: Text(T.autoSms.s, style: Txt.strong),
          subtitle: Text(T.autoSmsHint.s, style: Txt.tiny),
        ),
        const Gap(8),
        Align(alignment: Alignment.centerRight, child: BusyButton(label: T.save.s, icon: Icons.check_rounded, onPressed: _save)),
      ]),
    );
  }
}

// ---------------------------------------------------------------- security

class _SecuritySection extends ConsumerWidget {
  final Map<String, String> s;
  const _SecuritySection(this.s);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hasPin = s.str(K.pinHash).isNotEmpty;
    final autoLock = s.num(K.autoLockMinutes).toInt();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _sectionTitle(T.security.s),
      Panel(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Icon(hasPin ? Icons.verified_user_rounded : Icons.gpp_maybe_outlined, color: hasPin ? C.inGreen : C.warn, size: 28),
            const Gap(12),
            Expanded(child: Text(hasPin ? T.pinOn.s : T.pinOff.s, style: Txt.strong)),
          ]),
          const Gap(16),
          Wrap(spacing: 10, children: [
            FilledButton.icon(
              onPressed: () => _setPin(context, ref),
              icon: const Icon(Icons.pin_outlined, size: 18),
              label: Text(hasPin ? T.changePin.s : T.setPin.s),
            ),
            if (hasPin)
              OutlinedButton(
                onPressed: () async {
                  final ok = await confirmDialog(context, title: T.removePin.s, danger: true);
                  if (ok && context.mounted) await guard(context, () => ref.read(appProvider.notifier).setPin(null));
                },
                child: Text(T.removePin.s),
              ),
            if (hasPin)
              OutlinedButton.icon(
                onPressed: () => ref.read(appProvider.notifier).lock(),
                icon: const Icon(Icons.lock_outline_rounded, size: 18),
                label: Text('${T.lock.s} (Ctrl+L)'),
              ),
          ]),
          if (hasPin) ...[
            const Gap(18),
            const Divider(height: 1),
            const Gap(14),
            AdaptiveRow(children: [
              Expanded(child: Text(T.autoLock.s, style: Txt.strong)),
              SizedBox(
                width: 180,
                child: DropdownButtonFormField<int>(
                  initialValue: const [0, 1, 2, 5, 10, 15, 30].contains(autoLock) ? autoLock : 0,
                  isExpanded: true,
                  items: [
                    for (final m in const [0, 1, 2, 5, 10, 15, 30])
                      DropdownMenuItem(value: m, child: Text(m == 0 ? T.autoLockOff.s : T.minutesN.f({'n': number(m)}))),
                  ],
                  onChanged: (v) => ref.read(bizProvider).settings.set(K.autoLockMinutes, '${v ?? 0}'),
                ),
              ),
            ]),
          ],
        ]),
      ),
      const Gap(16),
      _StaffPanel(hasOwnerPin: hasPin),
    ]);
  }

  Future<void> _setPin(BuildContext context, WidgetRef ref) async {
    final a = TextEditingController();
    final b = TextEditingController();
    String? err;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AppDialog(
          title: T.setPin.s,
          icon: Icons.pin_outlined,
          width: 380,
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(T.cancel.s)),
            FilledButton(
              onPressed: () {
                if (a.text.length < 4) {
                  setD(() => err = T.newPin.s);
                } else if (a.text != b.text) {
                  setD(() => err = T.pinMismatch.s);
                } else {
                  Navigator.pop(ctx, true);
                }
              },
              child: Text(T.save.s),
            ),
          ],
          child: Column(children: [
            TextField(
              controller: a,
              autofocus: true,
              obscureText: true,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(6)],
              decoration: InputDecoration(labelText: T.newPin.s),
            ),
            const Gap(12),
            TextField(
              controller: b,
              obscureText: true,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(6)],
              decoration: InputDecoration(labelText: T.repeatPin.s, errorText: err),
            ),
          ]),
        ),
      ),
    );
    if (ok == true) {
      await ref.read(appProvider.notifier).setPin(a.text);
      if (context.mounted) toast(context, T.saved.s);
    }
    a.dispose();
    b.dispose();
  }
}

final _staffList = StreamProvider.autoDispose((ref) => ref.watch(bizProvider).staff.watchAll());

class _StaffPanel extends ConsumerWidget {
  final bool hasOwnerPin;
  const _StaffPanel({required this.hasOwnerPin});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final list = ref.watch(_staffList).value ?? const <StaffUser>[];
    return Panel(
      title: T.staff.s,
      trailing: hasOwnerPin
          ? FilledButton.tonalIcon(
              onPressed: () => showStaffDialog(context, ref),
              icon: const Icon(Icons.person_add_alt_1_outlined, size: 18),
              label: Text(T.addStaff.s),
            )
          : null,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(T.staffHint.s, style: Txt.small),
        const Gap(12),
        if (!hasOwnerPin)
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: C.warnSoft, borderRadius: BorderRadius.circular(10)),
            child: Row(children: [
              const Icon(Icons.info_outline_rounded, color: C.warn, size: 20),
              const Gap(10),
              Expanded(child: Text(T.needOwnerPin.s, style: Txt.small.copyWith(color: C.ink))),
            ]),
          )
        else if (list.isEmpty)
          Text(T.noStaff.s, style: Txt.small.copyWith(color: C.ink3))
        else
          for (final u in list)
            Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
              decoration: BoxDecoration(color: C.paper, borderRadius: BorderRadius.circular(10)),
              child: Row(children: [
                Avatar(u.name, size: 34, tone: u.active ? Tone.brand : Tone.neutral),
                const Gap(12),
                Expanded(
                  child: Cell2(u.name, u.active ? tKey('role', u.role) : '${tKey('role', u.role)} · ${T.staffInactive.s}'),
                ),
                IconButton(
                  tooltip: T.edit.s,
                  onPressed: () => showStaffDialog(context, ref, user: u),
                  icon: const Icon(Icons.edit_outlined, size: 19),
                ),
                IconButton(
                  tooltip: T.delete.s,
                  onPressed: () async {
                    final ok = await confirmDialog(context,
                        title: T.delete.s, message: T.removeStaffConfirm.f({'x': u.name}), danger: true, confirmLabel: T.delete.s);
                    if (ok) await ref.read(bizProvider).staff.remove(u.id);
                  },
                  icon: const Icon(Icons.delete_outline_rounded, size: 19, color: C.outRed),
                ),
              ]),
            ),
      ]),
    );
  }
}

/// Add a staff member, or edit one when [user] is given.
Future<void> showStaffDialog(BuildContext context, WidgetRef ref, {StaffUser? user}) async {
  final name = TextEditingController(text: user?.name ?? '');
  final pin = TextEditingController();
  final pin2 = TextEditingController();
  var role = user?.role ?? 'cashier';
  var active = user?.active ?? true;
  String? err;
  await showDialog<void>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setD) {
        Future<void> save() async {
          if (pin.text != pin2.text) {
            setD(() => err = T.pinMismatch.s);
            return;
          }
          try {
            final repo = ref.read(bizProvider).staff;
            if (user == null) {
              await repo.add(name: name.text, role: role, pin: pin.text);
            } else {
              await repo.update(user.id, name: name.text, role: role, newPin: pin.text, active: active);
            }
            if (ctx.mounted) Navigator.pop(ctx);
          } catch (e) {
            setD(() => err = errorText(e));
          }
        }

        Widget roleTile(String value, String hint) => Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Material(
                color: role == value ? C.brandSoft : C.paper,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10), side: BorderSide(color: role == value ? C.brand : C.line)),
                child: InkWell(
                  borderRadius: BorderRadius.circular(10),
                  onTap: () => setD(() => role = value),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(8, 8, 12, 8),
                    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Icon(role == value ? Icons.radio_button_checked_rounded : Icons.radio_button_off_rounded,
                          size: 20, color: role == value ? C.brand : C.ink3),
                      const Gap(8),
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(tKey('role', value), style: Txt.strong),
                          Text(hint, style: Txt.small),
                        ]),
                      ),
                    ]),
                  ),
                ),
              ),
            );

        final pinFormat = [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(6)];
        return AppDialog(
          title: user == null ? T.addStaff.s : T.editStaff.s,
          icon: Icons.badge_outlined,
          width: 460,
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: Text(T.cancel.s)),
            FilledButton(onPressed: save, child: Text(T.save.s)),
          ],
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            TextField(
              controller: name,
              autofocus: user == null,
              textCapitalization: TextCapitalization.words,
              decoration: InputDecoration(labelText: T.staffName.s),
            ),
            const Gap(14),
            Text(T.role.s, style: Txt.label),
            const Gap(6),
            roleTile('cashier', T.roleCashierHint.s),
            roleTile('manager', T.roleManagerHint.s),
            const Gap(6),
            FieldRow(minFieldWidth: 150, children: [
              TextField(
                controller: pin,
                obscureText: true,
                keyboardType: TextInputType.number,
                inputFormatters: pinFormat,
                decoration: InputDecoration(labelText: user == null ? T.staffPin.s : T.newPinOptional.s),
              ),
              TextField(
                controller: pin2,
                obscureText: true,
                keyboardType: TextInputType.number,
                inputFormatters: pinFormat,
                decoration: InputDecoration(labelText: T.repeatPin.s),
                onSubmitted: (_) => save(),
              ),
            ]),
            if (user != null) ...[
              const Gap(6),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: active,
                onChanged: (v) => setD(() => active = v),
                title: Text(T.staffActive.s, style: Txt.body),
              ),
            ],
            if (err != null) ...[
              const Gap(8),
              Text(err!, style: Txt.small.copyWith(color: C.outRed)),
            ],
          ]),
        );
      },
    ),
  );
  name.dispose();
  pin.dispose();
  pin2.dispose();
}

// ---------------------------------------------------------------- backup

class _BackupSection extends ConsumerStatefulWidget {
  final Map<String, String> s;
  const _BackupSection(this.s);
  @override
  ConsumerState<_BackupSection> createState() => _BackupSectionState();
}

class _BackupSectionState extends ConsumerState<_BackupSection> {
  String? defaultDir;
  String? dataDir;

  @override
  void initState() {
    super.initState();
    Future.microtask(() async {
      try {
        final d = await BusinessStore.defaultBackupDir();
        final f = await BusinessStore.folder(ref.read(sessionProvider).info.id);
        if (mounted) {
          setState(() {
            defaultDir = d.path;
            dataDir = f.path;
          });
        }
      } catch (_) {
        // Paths are informational; the section still works without them.
      }
    });
  }

  Future<void> _backupNow() async {
    final session = ref.read(sessionProvider);
    await guard(context, () async {
      final tmp = p.join(Directory.systemTemp.path, 'bizkhata-backup-${DateTime.now().millisecondsSinceEpoch}.bizkhata');
      final f = await BusinessStore.backupTo(session.biz.db, tmp);
      final bytes = await f.readAsBytes();
      final name = '${session.info.name.replaceAll(RegExp(r'[^\wঀ-৿ -]'), '_')} ${fileStamp(DateTime.now())}.bizkhata';
      final saved = await FilePicker.saveFile(fileName: name, bytes: bytes, type: FileType.any);
      try {
        f.deleteSync();
      } catch (_) {}
      if (saved != null) {
        await session.biz.settings.set(K.lastBackupAt, DateTime.now().toIso8601String());
        if (mounted) toast(context, T.backupSaved.s);
      }
    });
  }

  /// Same backup file, sent through the share sheet (Drive, email, WhatsApp, Nearby Share).
  Future<void> _shareBackup() async {
    final session = ref.read(sessionProvider);
    await guard(context, () async {
      final name = '${session.info.name.replaceAll(RegExp(r'[^\wঀ-৿ -]'), '_')} ${fileStamp(DateTime.now())}.bizkhata';
      final f = await BusinessStore.backupTo(session.biz.db, p.join(Directory.systemTemp.path, name));
      await SharePlus.instance.share(ShareParams(files: [XFile(f.path, mimeType: 'application/octet-stream')], subject: name));
      await session.biz.settings.set(K.lastBackupAt, DateTime.now().toIso8601String());
    });
  }

  Future<void> _restore() async {
    final f = await FilePicker.pickFile(type: FileType.any, dialogTitle: T.restore.s);
    if (f == null || !mounted) return;
    var path = f.path;
    if (path == null) {
      // Content link (Android): copy to a temporary file first.
      final tmp = File(p.join(Directory.systemTemp.path, 'restore-${DateTime.now().millisecondsSinceEpoch}.bizkhata'));
      await tmp.writeAsBytes(await f.readAsBytes());
      path = tmp.path;
    }
    if (!mounted) return;
    if (!await BusinessStore.looksValid(path)) {
      if (mounted) toast(context, T.invalidBackup.s, error: true);
      return;
    }
    if (!mounted) return;
    final ok = await confirmDialog(context, title: T.restore.s, message: T.restoreWarn.s, danger: true, confirmLabel: T.restore.s);
    if (!ok || !mounted) return;
    final router = GoRouter.of(context);
    final source = path;
    await guard(context, () => ref.read(appProvider.notifier).restore(source));
    router.go('/');
  }

  @override
  Widget build(BuildContext context) {
    final last = DateTime.tryParse(widget.s.str(K.lastBackupAt));
    final dir = widget.s.str(K.backupDir);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _sectionTitle(T.backup.s, T.autoBackupInfo.s),
      Panel(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            const Icon(Icons.history_rounded, color: C.ink2),
            const Gap(10),
            Text('${T.lastBackup.s}: ', style: Txt.small),
            Text(last == null ? '—' : friendlyDate(last), style: Txt.strong),
          ]),
          const Gap(16),
          Wrap(spacing: 10, runSpacing: 10, children: [
            BusyButton(label: T.backupNow.s, icon: Icons.save_alt_rounded, onPressed: _backupNow),
            OutlinedButton.icon(onPressed: _shareBackup, icon: const Icon(Icons.share_outlined, size: 18), label: Text(T.shareBackup.s)),
            OutlinedButton.icon(onPressed: _restore, icon: const Icon(Icons.restore_rounded, size: 18), label: Text(T.restore.s)),
          ]),
          const Gap(8),
          Text(T.shareBackupHint.s, style: Txt.tiny),
        ]),
      ),
      // Phones keep automatic backups inside the app; "Backup now" saves a copy anywhere.
      if (!isMobilePlatform) ...[
      const Gap(16),
      Panel(
        title: T.backupFolder.s,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          SelectableText(dir.isNotEmpty ? dir : (defaultDir ?? '…'), style: Txt.strong),
          const Gap(4),
          Text(T.backupFolderHint.s, style: Txt.tiny),
          const Gap(12),
          Wrap(spacing: 10, children: [
            OutlinedButton.icon(
              onPressed: () async {
                final d = await FilePicker.getDirectoryPath(dialogTitle: T.backupFolder.s);
                if (d != null) await ref.read(bizProvider).settings.set(K.backupDir, d);
              },
              icon: const Icon(Icons.folder_open_rounded, size: 18),
              label: Text(T.changeFolder.s),
            ),
            TextButton.icon(
              onPressed: () => Messaging.openUrl(Uri.file(dir.isNotEmpty ? dir : (defaultDir ?? '')).toString()),
              icon: const Icon(Icons.open_in_new_rounded, size: 17),
              label: Text(T.open.s),
            ),
          ]),
        ]),
      ),
      ],
      const Gap(16),
      Panel(
        title: T.dataFolder.s,
        child: Row(children: [
          Expanded(child: SelectableText(dataDir ?? '…', style: Txt.small)),
          if (!isMobilePlatform)
            TextButton.icon(
              onPressed: dataDir == null ? null : () => Messaging.openUrl(Uri.file(dataDir!).toString()),
              icon: const Icon(Icons.open_in_new_rounded, size: 17),
              label: Text(T.open.s),
            ),
        ]),
      ),
    ]);
  }
}

// ---------------------------------------------------------------- about

class _AboutSection extends ConsumerWidget {
  const _AboutSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionProvider);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _sectionTitle(T.about.s),
      Panel(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(T.appName.s, style: Txt.display(24)),
          Text(T.tagline.s, style: Txt.small),
          const Gap(10),
          Text('${T.version.s} $appVersion', style: Txt.body),
          const Gap(14),
          Text(T.shortcuts.s, style: Txt.strong),
          const Gap(8),
          for (final (k, v) in [
            ('F2', T.newSale.s),
            ('F3', T.products.s),
            ('F4', T.customers.s),
            ('F5', T.orders.s),
            ('F6', T.purchases.s),
            ('F7', T.expenses.s),
            ('F8', T.cashbox.s),
            ('F10', T.reports.s),
            ('F9 / Ctrl+Enter', T.completeSale.s),
            ('F12', T.selectCustomer.s),
            ('Ctrl+N', T.addProduct.s),
            ('Ctrl+K', T.search.s),
            ('Ctrl+L', T.lock.s),
          ])
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(children: [SizedBox(width: 130, child: KeyCap(k)), Text(v, style: Txt.small)]),
            ),
        ]),
      ),
      if (session.actor.isOwner) ...[
      const Gap(16),
      Panel(
        color: C.outSoft,
        title: T.dangerZone.s,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(T.deleteBusinessWarn.s, style: Txt.small.copyWith(color: C.outRed)),
          const Gap(12),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              style: OutlinedButton.styleFrom(foregroundColor: C.outRed, side: const BorderSide(color: C.outRed)),
              onPressed: () => _delete(context, ref, session.info.name),
              icon: const Icon(Icons.delete_forever_outlined, size: 18),
              label: Text(T.deleteBusiness.s),
            ),
          ),
        ]),
      ),
      ],
    ]);
  }

  Future<void> _delete(BuildContext context, WidgetRef ref, String name) async {
    final c = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AppDialog(
          title: T.deleteBusiness.s,
          icon: Icons.warning_amber_rounded,
          tone: Tone.bad,
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(T.cancel.s)),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: C.outRed),
              onPressed: c.text.trim() == name.trim() ? () => Navigator.pop(ctx, true) : null,
              child: Text(T.delete.s),
            ),
          ],
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(T.deleteBusinessWarn.s, style: Txt.body),
            const Gap(12),
            Text('${T.typeToConfirm.s}: $name', style: Txt.label),
            const Gap(8),
            TextField(controller: c, autofocus: true, onChanged: (_) => setD(() {})),
          ]),
        ),
      ),
    );
    c.dispose();
    if (ok == true) await ref.read(appProvider.notifier).deleteCurrent();
  }
}
