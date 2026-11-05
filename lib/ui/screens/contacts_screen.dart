import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/format.dart';
import '../../core/i18n.dart';
import '../../core/theme.dart';
import '../../core/util.dart';
import '../../data/biz.dart';
import '../../services/messaging.dart';
import '../../services/templates.dart';
import '../../services/print_service.dart';
import '../../state/app_state.dart';
import '../widgets/common.dart';

typedef _ListArgs = (String type, String query, ContactSort sort, bool onlyDue);

final _contacts = StreamProvider.autoDispose.family<List<ContactWithBalance>, _ListArgs>(
    (ref, a) => ref.watch(bizProvider).contacts.watchContacts(a.$1, query: a.$2, sort: a.$3, onlyWithBalance: a.$4));
final _totals = StreamProvider.autoDispose((ref) => ref.watch(bizProvider).contacts.watchTotals());
final _contact = StreamProvider.autoDispose.family<Contact?, int>((ref, id) => ref.watch(bizProvider).contacts.watchById(id));
final _ledger = StreamProvider.autoDispose.family<List<LedgerLine>, int>((ref, id) => ref.watch(bizProvider).contacts.watchLedger(id));

class ContactsScreen extends ConsumerStatefulWidget {
  final String type;
  final int? selectedId;
  const ContactsScreen({super.key, required this.type, this.selectedId});
  @override
  ConsumerState<ContactsScreen> createState() => _ContactsScreenState();
}

class _ContactsScreenState extends ConsumerState<ContactsScreen> {
  String query = '';
  ContactSort sort = ContactSort.recent;
  bool onlyDue = false;

  bool get isCustomer => widget.type == 'customer';
  String get base => isCustomer ? '/customers' : '/suppliers';

  Future<void> _import(BuildContext context) async {
    final ok = await confirmDialog(context, title: T.importContacts.s, message: T.importContactsHint.s, confirmLabel: T.open.s);
    if (!ok) return;
    final f = await FilePicker.pickFile(type: FileType.custom, allowedExtensions: ['csv', 'txt']);
    if (f == null || !context.mounted) return;
    await guard(context, () async {
      final rows = parseCsv(utf8.decode(await f.readAsBytes(), allowMalformed: true));
      final r = await ref.read(bizProvider).contacts.importCsv(widget.type, rows);
      if (context.mounted) toast(context, T.importedN.f({'n': number(r.created), 's': number(r.skipped)}));
    });
  }

  @override
  Widget build(BuildContext context) {
    final list = ref.watch(_contacts((widget.type, query, sort, onlyDue)));
    final totals = ref.watch(_totals).value;
    final total = isCustomer ? (totals?.receivable ?? 0) : (totals?.payable ?? 0);
    final compact = context.isCompact;
    final listPanel = Container(
        width: compact ? null : (MediaQuery.sizeOf(context).width < 1200 ? 320 : 400),
        decoration: const BoxDecoration(border: Border(right: BorderSide(color: C.line))),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(22, 22, 18, 12),
            child: Row(children: [
              Expanded(child: Text(isCustomer ? T.customers.s : T.suppliers.s, style: Txt.display(26))),
              PopupMenuButton<String>(
                tooltip: T.more.s,
                icon: const Icon(Icons.more_vert_rounded),
                onSelected: (v) => switch (v) {
                  'import' => _import(context),
                  'template' => guard(context, () => saveCsv('bizkhata-${widget.type}s-template', [
                        ContactRepo.importHeaders,
                        ['Rahim Uddin', '01711000001', 'Mirpur 10, Dhaka', '', 1500, ''],
                      ])),
                  _ => guard(context, () async {
                      await saveCsv('bizkhata-${widget.type}s-${fileStamp(DateTime.now())}',
                          await ref.read(bizProvider).contacts.exportRows(widget.type));
                    }),
                },
                itemBuilder: (_) => [
                  PopupMenuItem(value: 'import', child: Text(T.importContacts.s)),
                  PopupMenuItem(value: 'template', child: Text(T.downloadTemplate.s)),
                  PopupMenuItem(value: 'export', child: Text(T.exportCsv.s)),
                ],
              ),
              FilledButton.icon(
                onPressed: () => showContactForm(context, ref, widget.type),
                icon: const Icon(Icons.person_add_alt_1_outlined, size: 18),
                label: Text(T.add.s),
              ),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 22),
            child: Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: isCustomer ? C.inSoft : C.outSoft,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(children: [
                Icon(isCustomer ? Icons.south_west_rounded : Icons.north_east_rounded,
                    color: isCustomer ? C.inGreen : C.outRed, size: 20),
                const Gap(10),
                Expanded(
                  child: Text(isCustomer ? T.totalReceivable.s : T.totalPayable.s,
                      style: Txt.strong.copyWith(color: isCustomer ? C.inGreen : C.outRed)),
                ),
                Text(money(total), style: Txt.display(22, color: isCustomer ? C.inGreen : C.outRed)),
              ]),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(22, 12, 22, 8),
            child: SearchBox(hint: '${T.name.s} / ${T.phone.s}', width: double.infinity, onChanged: (v) => setState(() => query = v)),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 0, 18, 6),
            child: Row(children: [
              for (final s in ContactSort.values)
                Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: ChoiceChip(
                    label: Text(switch (s) {
                      ContactSort.recent => T.sortRecent.s,
                      ContactSort.name => T.sortName.s,
                      ContactSort.balanceDesc => T.sortBalance.s,
                    }),
                    selected: sort == s,
                    onSelected: (_) => setState(() => sort = s),
                  ),
                ),
              const Spacer(),
              Tooltip(
                message: T.onlyWithDue.s,
                child: FilterChip(
                  label: Text(T.due.s),
                  selected: onlyDue,
                  onSelected: (v) => setState(() => onlyDue = v),
                ),
              ),
            ]),
          ),
          const Divider(),
          Expanded(
            child: AsyncView(list, builder: (rows) {
              if (rows.isEmpty) {
                return EmptyState(
                  icon: Icons.people_outline_rounded,
                  text: T.noData.s,
                  action: OutlinedButton.icon(
                    onPressed: () => showContactForm(context, ref, widget.type),
                    icon: const Icon(Icons.add_rounded, size: 18),
                    label: Text(isCustomer ? T.addCustomer.s : T.addSupplier.s),
                  ),
                );
              }
              return ListView.builder(
                itemCount: rows.length,
                itemBuilder: (_, i) => _ContactTile(
                  c: rows[i],
                  selected: rows[i].contact.id == widget.selectedId,
                  onTap: () => context.go('$base/${rows[i].contact.id}'),
                ),
              );
            }),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 8),
            decoration: const BoxDecoration(border: Border(top: BorderSide(color: C.line2))),
            child: Text(T.contactsCount.f({'n': number(list.value?.length ?? 0)}), style: Txt.tiny),
          ),
        ]),
      );
    // Phones / narrow windows: the list or one person's khata, not both.
    if (compact) {
      return widget.selectedId == null
          ? listPanel
          : _LedgerPanel(key: ValueKey(widget.selectedId), id: widget.selectedId!, type: widget.type);
    }
    return Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      listPanel,
      Expanded(
        child: widget.selectedId == null
            ? _Placeholder(isCustomer: isCustomer)
            : _LedgerPanel(key: ValueKey(widget.selectedId), id: widget.selectedId!, type: widget.type),
      ),
    ]);
  }
}

class _ContactTile extends StatelessWidget {
  final ContactWithBalance c;
  final bool selected;
  final VoidCallback onTap;
  const _ContactTile({required this.c, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final b = c.balance;
    final settled = b.abs() < 0.01;
    return Material(
      color: selected ? C.brandSoft : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.fromLTRB(22, 11, 22, 11),
          decoration: BoxDecoration(
            border: Border(
              left: BorderSide(color: selected ? C.brand : Colors.transparent, width: 3),
              bottom: const BorderSide(color: C.line2),
            ),
          ),
          child: Row(children: [
            Avatar(c.contact.name, size: 38, tone: settled ? Tone.neutral : (b > 0 ? Tone.good : Tone.bad)),
            const Gap(12),
            Expanded(
              child: Cell2(
                c.contact.name,
                [
                  if (c.contact.phone != null) digits(c.contact.phone!),
                  if (c.lastActivity != null) friendlyDate(c.lastActivity!, withTime: false),
                ].join(' · '),
              ),
            ),
            settled
                ? Text(T.settled.s, style: Txt.tiny)
                : Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                    Text(money(b.abs()), style: Txt.num.copyWith(color: b > 0 ? C.inGreen : C.outRed, fontSize: 15)),
                    Text(b > 0 ? T.willGet.s : T.willGive.s, style: Txt.tiny),
                  ]),
          ]),
        ),
      ),
    );
  }
}

class _Placeholder extends StatelessWidget {
  final bool isCustomer;
  const _Placeholder({required this.isCustomer});
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        CustomPaint(size: const Size(150, 110), painter: _LedgerArt()),
        const Gap(18),
        Text(T.sectionKhata.s, style: Txt.display(24)),
        const Gap(6),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: Text(
            isBangla
                ? 'বাঁ দিক থেকে কাউকে বাছাই করে তার খাতা দেখুন। দিলাম (বাকিতে দিলেন) আর পেলাম (টাকা পেলেন) — এভাবেই হিসাব রাখুন।'
                : 'Pick someone on the left to open their khata. Record "You gave" (credit given) and "You got" (money received) — that\'s it.',
            textAlign: TextAlign.center,
            style: Txt.small,
          ),
        ),
      ]),
    );
  }
}

class _LedgerArt extends CustomPainter {
  @override
  void paint(Canvas canvas, Size s) {
    final page = RRect.fromRectAndRadius(Offset.zero & s, const Radius.circular(12));
    canvas.drawRRect(page, Paint()..color = C.card);
    canvas.drawRRect(page, Paint()
      ..color = C.line
      ..style = PaintingStyle.stroke);
    final rule = Paint()..color = C.line2;
    for (double y = 22; y < s.height - 6; y += 16) {
      canvas.drawLine(Offset(10, y), Offset(s.width - 10, y), rule);
    }
    canvas.drawLine(const Offset(30, 6), Offset(30, s.height - 6), Paint()
      ..color = C.margin
      ..strokeWidth = 1.5);
    final green = Paint()..color = C.inGreen;
    final red = Paint()..color = C.outRed;
    canvas.drawRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(40, 18, 46, 8), const Radius.circular(4)), green);
    canvas.drawRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(96, 34, 36, 8), const Radius.circular(4)), red);
    canvas.drawRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(40, 50, 60, 8), const Radius.circular(4)), green);
    canvas.drawRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(96, 66, 30, 8), const Radius.circular(4)), red);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

// =============================================================== ledger

class _LedgerPanel extends ConsumerWidget {
  final int id;
  final String type;
  const _LedgerPanel({super.key, required this.id, required this.type});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final contact = ref.watch(_contact(id));
    final ledger = ref.watch(_ledger(id));
    final biz = ref.watch(bizProvider);
    final settings = ref.watch(settingsProvider).value ?? const {};

    return AsyncView(contact, builder: (c) {
      if (c == null) return EmptyState(icon: Icons.person_off_outlined, text: T.e_not_found.s);
      final lines = ledger.value ?? const <LedgerLine>[];
      final balance = lines.isEmpty ? 0.0 : lines.first.running;
      final settled = balance.abs() < 0.01;
      final tone = settled ? Tone.neutral : (balance > 0 ? Tone.good : Tone.bad);
      final reminder = dueMessage(settings, c.name, balance.abs());

      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: EdgeInsets.fromLTRB(context.isPhone ? 6 : 28, context.isPhone ? 12 : 22, context.isPhone ? 6 : 22, 6),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (context.isCompact)
              IconButton(
                onPressed: () => context.go(type == 'customer' ? '/customers' : '/suppliers'),
                icon: const Icon(Icons.arrow_back_rounded),
              ),
            Avatar(c.name, size: context.isPhone ? 40 : 52, tone: tone == Tone.neutral ? Tone.brand : tone),
            const Gap(14),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(c.name, style: Txt.display(context.isPhone ? 20 : 24), maxLines: 2, overflow: TextOverflow.ellipsis),
                const Gap(4),
                Wrap(spacing: 14, runSpacing: 4, children: [
                  if (c.phone != null) _meta(Icons.phone_outlined, digits(c.phone!)),
                  if (c.address != null) _meta(Icons.place_outlined, c.address!),
                  if (c.email != null) _meta(Icons.alternate_email_rounded, c.email!),
                ]),
              ]),
            ),
            PopupMenuButton<String>(
              tooltip: T.more.s,
              icon: const Icon(Icons.more_horiz_rounded),
              onSelected: (v) async {
                switch (v) {
                  case 'edit':
                    showContactForm(context, ref, type, contact: c);
                  case 'print':
                    guard(context, () => PrintService.printStatement(context, biz, c.id));
                  case 'pdf':
                    guard(context, () => PrintService.printStatement(context, biz, c.id, save: true));
                  case 'archive':
                    final ok = await confirmDialog(context, title: '${T.archive.s}: ${c.name}', danger: true, confirmLabel: T.archive.s);
                    if (ok && context.mounted && await guard(context, () => biz.contacts.archive(c.id)) && context.mounted) {
                      context.go(type == 'customer' ? '/customers' : '/suppliers');
                    }
                }
              },
              itemBuilder: (_) => [
                PopupMenuItem(value: 'edit', child: _mi(Icons.edit_outlined, T.edit.s)),
                PopupMenuItem(value: 'print', child: _mi(Icons.print_outlined, '${T.statement.s} · ${T.print.s}')),
                PopupMenuItem(value: 'pdf', child: _mi(Icons.picture_as_pdf_outlined, '${T.statement.s} · PDF')),
                if (ref.watch(actorProvider).can(Cap.delete))
                  PopupMenuItem(value: 'archive', child: _mi(Icons.archive_outlined, T.archive.s, color: C.outRed)),
              ],
            ),
          ]),
        ),
        Padding(
          padding: EdgeInsets.fromLTRB(context.gutter, 10, context.gutter, 0),
          child: LayoutBuilder(builder: (context, box) {
            final balanceBox = Container(
              padding: const EdgeInsets.fromLTRB(18, 14, 18, 14),
              decoration: BoxDecoration(color: tone.bg, borderRadius: BorderRadius.circular(14)),
              child: Row(children: [
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(settled ? T.settled.s : (balance > 0 ? T.willGet.s : T.willGive.s),
                        style: Txt.strong.copyWith(color: tone.fg)),
                    const Gap(2),
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: Text(money(balance.abs()), style: Txt.display(34, color: tone.fg)),
                    ),
                  ]),
                ),
                if (!settled && balance > 0 && c.phone != null) ...[
                  _roundBtn(Icons.chat_outlined, T.whatsapp.s, () => Messaging.whatsapp(c.phone!, reminder)),
                  const Gap(6),
                  _roundBtn(Icons.sms_outlined, T.sms.s,
                      () => guard(context, () => Messaging.sms(biz, c.phone!, reminder), success: T.smsSent.s)),
                  const Gap(6),
                ],
                if (c.phone != null) _roundBtn(Icons.call_outlined, T.call.s, () => Messaging.call(c.phone!)),
              ]),
            );
            // Side by side when there is room, stacked on small windows.
            if (box.maxWidth >= 600) {
              return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(child: balanceBox),
                const Gap(12),
                Column(children: [
                  _bigAction(context, ref, c, gave: true),
                  const Gap(8),
                  _bigAction(context, ref, c, gave: false),
                ]),
              ]);
            }
            return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              balanceBox,
              const Gap(10),
              FieldRow(children: [_bigAction(context, ref, c, gave: true), _bigAction(context, ref, c, gave: false)]),
            ]);
          }),
        ),
        const Gap(14),
        Expanded(
          child: Container(
            margin: EdgeInsets.fromLTRB(context.isPhone ? 0 : context.gutter, 0, context.isPhone ? 0 : context.gutter, context.isPhone ? 0 : 22),
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(color: C.card, borderRadius: BorderRadius.circular(14), border: Border.all(color: C.line)),
            child: Column(children: [
              _ledgerHead(context),
              Expanded(
                child: lines.isEmpty
                    ? EmptyState(icon: Icons.menu_book_outlined, text: T.noEntries.s)
                    : CustomPaint(
                        painter: _MarginPainter(ledgerInset(context)),
                        child: ListView.builder(
                          itemCount: lines.length,
                          itemBuilder: (_, i) => _LedgerRow(line: lines[i], biz: biz, canDelete: ref.watch(actorProvider).can(Cap.delete)),
                        ),
                      ),
              ),
            ]),
          ),
        ),
      ]);
    });
  }

  Widget _meta(IconData i, String t) => Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(i, size: 14, color: C.ink3),
        const Gap(4),
        Text(t, style: Txt.small),
      ]);

  Widget _mi(IconData i, String t, {Color? color}) => Row(children: [
        Icon(i, size: 18, color: color ?? C.ink2),
        const Gap(10),
        Text(t, style: TextStyle(color: color)),
      ]);

  Widget _roundBtn(IconData i, String tip, VoidCallback onTap) => Tooltip(
        message: tip,
        child: Material(
          color: Colors.white.withValues(alpha: 0.7),
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onTap,
            child: SizedBox(width: 40, height: 40, child: Icon(i, size: 19, color: C.ink2)),
          ),
        ),
      );

  Widget _bigAction(BuildContext context, WidgetRef ref, Contact c, {required bool gave}) {
    final color = gave ? C.outRed : C.inGreen;
    return SizedBox(
      width: 170,
      height: 44,
      child: FilledButton.icon(
        style: FilledButton.styleFrom(backgroundColor: color),
        onPressed: () => showEntryDialog(context, ref, c, gave: gave),
        icon: Icon(gave ? Icons.north_east_rounded : Icons.south_west_rounded, size: 18),
        label: Text(gave ? T.youGave.s : T.youGot.s),
      ),
    );
  }

  Widget _ledgerHead(BuildContext context) => Container(
        padding: EdgeInsets.fromLTRB(ledgerInset(context), 10, context.isPhone ? 10 : 18, 10),
        decoration: const BoxDecoration(color: C.paper, border: Border(bottom: BorderSide(color: C.line))),
        child: Row(children: [
          Expanded(flex: 5, child: Text('${T.date.s} · ${T.details.s}'.toUpperCase(), style: Txt.caps)),
          Expanded(flex: 2, child: Text(T.youGave.s.toUpperCase(), textAlign: TextAlign.right, style: Txt.caps.copyWith(color: C.outRed))),
          Expanded(flex: 2, child: Text(T.youGot.s.toUpperCase(), textAlign: TextAlign.right, style: Txt.caps.copyWith(color: C.inGreen))),
          Expanded(flex: 2, child: Text(T.balance.s.toUpperCase(), textAlign: TextAlign.right, style: Txt.caps)),
          SizedBox(width: context.isPhone ? 0 : 36),
        ]),
      );
}

/// Left inset of the ledger page (room for the red margin line).
double ledgerInset(BuildContext context) => context.isPhone ? 26 : 56;

/// Red double margin line down the left of the khata page.
class _MarginPainter extends CustomPainter {
  final double inset;
  _MarginPainter(this.inset);

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = C.margin.withValues(alpha: 0.55)
      ..strokeWidth = 1.2;
    final x = inset - 16;
    canvas.drawLine(Offset(x, 0), Offset(x, size.height), p);
    canvas.drawLine(Offset(x + 3.5, 0), Offset(x + 3.5, size.height), p);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _LedgerRow extends StatefulWidget {
  final LedgerLine line;
  final Biz biz;
  final bool canDelete;
  const _LedgerRow({required this.line, required this.biz, this.canDelete = true});
  @override
  State<_LedgerRow> createState() => _LedgerRowState();
}

class _LedgerRowState extends State<_LedgerRow> {
  bool hover = false;

  Future<void> _delete() async {
    final ok = await confirmDialog(context, title: T.areYouSure.s, message: T.cannotUndo.s, danger: true, confirmLabel: T.delete.s);
    if (ok && mounted) await guard(context, () => widget.biz.contacts.deleteEntry(widget.line.entry.id), success: T.deleted.s);
  }

  @override
  Widget build(BuildContext context) {
    final e = widget.line.entry;
    final manual = widget.canDelete && const {'gave', 'got', 'opening'}.contains(e.kind);
    final linked = e.refType == 'sale' || e.refType == 'purchase';
    final run = widget.line.running;
    return MouseRegion(
      onEnter: (_) => setState(() => hover = true),
      onExit: (_) => setState(() => hover = false),
      child: InkWell(
        onTap: linked && e.refId != null ? () => context.go(e.refType == 'sale' ? '/sales/${e.refId}' : '/purchases') : null,
        // Touch screens have no hover: long-press deletes a hand-made entry.
        onLongPress: manual ? _delete : null,
        child: Container(
          padding: EdgeInsets.fromLTRB(ledgerInset(context), 10, context.isPhone ? 10 : 18, 10),
          decoration: BoxDecoration(
            color: hover ? C.paper.withValues(alpha: 0.6) : null,
            border: const Border(bottom: BorderSide(color: C.line2)),
          ),
          child: Row(children: [
            Expanded(
              flex: 5,
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(friendlyDate(e.date), style: Txt.strong.copyWith(fontSize: 13.5)),
                Text([tKey('k', e.kind), if (e.note != null && e.note!.isNotEmpty) e.note!].join(' · '),
                    style: Txt.tiny, maxLines: 2, overflow: TextOverflow.ellipsis),
              ]),
            ),
            Expanded(
              flex: 2,
              child: Text(e.amount > 0 ? money(e.amount) : '',
                  textAlign: TextAlign.right, style: Txt.num.copyWith(color: C.outRed)),
            ),
            Expanded(
              flex: 2,
              child: Text(e.amount < 0 ? money(-e.amount) : '',
                  textAlign: TextAlign.right, style: Txt.num.copyWith(color: C.inGreen)),
            ),
            Expanded(
              flex: 2,
              child: Text(money(run.abs()),
                  textAlign: TextAlign.right,
                  style: Txt.num.copyWith(color: run.abs() < 0.01 ? C.ink3 : (run > 0 ? C.inGreen : C.outRed), fontWeight: FontWeight.w500)),
            ),
            if (!context.isPhone)
              SizedBox(
                width: 36,
                child: manual && hover
                    ? IconButton(
                        tooltip: T.delete.s,
                        iconSize: 17,
                        onPressed: _delete,
                        icon: const Icon(Icons.delete_outline_rounded, color: C.outRed),
                      )
                    : (linked ? const Icon(Icons.chevron_right_rounded, size: 18, color: C.ink3) : null),
              ),
          ]),
        ),
      ),
    );
  }
}

// =============================================================== dialogs

Future<void> showEntryDialog(BuildContext context, WidgetRef ref, Contact c, {required bool gave}) =>
    showDialog(context: context, builder: (_) => _EntryDialog(contact: c, gave: gave));

class _EntryDialog extends ConsumerStatefulWidget {
  final Contact contact;
  final bool gave;
  const _EntryDialog({required this.contact, required this.gave});
  @override
  ConsumerState<_EntryDialog> createState() => _EntryDialogState();
}

class _EntryDialogState extends ConsumerState<_EntryDialog> {
  final amount = TextEditingController();
  final note = TextEditingController();
  DateTime date = DateTime.now();
  int? accountId;
  bool cashMoved = true;

  @override
  void initState() {
    super.initState();
    // Customer "gave" is usually goods on credit; supplier "got" is goods on credit.
    final isCustomer = widget.contact.type == 'customer';
    cashMoved = isCustomer ? !widget.gave : widget.gave;
    Future.microtask(() async {
      final id = await ref.read(bizProvider).cash.defaultCashAccount();
      if (mounted) setState(() => accountId = id);
    });
  }

  @override
  void dispose() {
    amount.dispose();
    note.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final biz = ref.read(bizProvider);
    final now = DateTime.now();
    final when = DateTime(date.year, date.month, date.day, now.hour, now.minute, now.second);
    final ok = await guard(context, () async {
      await biz.contacts.addEntry(
        contactId: widget.contact.id,
        gave: widget.gave,
        amount: parseNum(amount.text),
        accountId: cashMoved ? accountId : null,
        note: note.text,
        date: when,
      );
    }, success: T.saved.s);
    if (ok && mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.gave ? C.outRed : C.inGreen;
    return AppDialog(
      title: '${widget.gave ? T.youGave.s : T.youGot.s} · ${widget.contact.name}',
      icon: widget.gave ? Icons.north_east_rounded : Icons.south_west_rounded,
      tone: widget.gave ? Tone.bad : Tone.good,
      width: 480,
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(T.cancel.s)),
        FilledButton(style: FilledButton.styleFrom(backgroundColor: color), onPressed: _save, child: Text(T.save.s)),
      ],
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(widget.gave ? T.youGaveHint.s : T.youGotHint.s, style: Txt.small),
        const Gap(14),
        TextField(
          controller: amount,
          autofocus: true,
          inputFormatters: [NumberInputFormatter()],
          style: Txt.display(30, color: color),
          decoration: InputDecoration(labelText: T.amount.s, prefixText: '৳ '),
          onSubmitted: (_) => _save(),
        ),
        const Gap(14),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: cashMoved,
          onChanged: (v) => setState(() => cashMoved = v),
          title: Text(cashMoved ? T.moneyMoved.s : T.noMoneyMoved.s, style: Txt.strong),
        ),
        if (cashMoved) AccountChips(value: accountId, onChanged: (v) => setState(() => accountId = v)),
        const Gap(14),
        Row(children: [
          Expanded(child: TextIn(controller: note, label: T.noteOptional.s)),
          const Gap(10),
          OutlinedButton.icon(
            onPressed: () async {
              final d = await showDatePicker(context: context, firstDate: DateTime(2015), lastDate: DateTime.now(), initialDate: date);
              if (d != null) setState(() => date = d);
            },
            icon: const Icon(Icons.event_outlined, size: 18),
            label: Text(dateShort(date)),
          ),
        ]),
      ]),
    );
  }
}

Future<void> showContactForm(BuildContext context, WidgetRef ref, String type, {Contact? contact}) =>
    showDialog(context: context, builder: (_) => _ContactForm(type: type, contact: contact));

class _ContactForm extends ConsumerStatefulWidget {
  final String type;
  final Contact? contact;
  const _ContactForm({required this.type, this.contact});
  @override
  ConsumerState<_ContactForm> createState() => _ContactFormState();
}

class _ContactFormState extends ConsumerState<_ContactForm> {
  late final name = TextEditingController(text: widget.contact?.name ?? '');
  late final phone = TextEditingController(text: widget.contact?.phone ?? '');
  late final address = TextEditingController(text: widget.contact?.address ?? '');
  late final email = TextEditingController(text: widget.contact?.email ?? '');
  late final note = TextEditingController(text: widget.contact?.note ?? '');
  final opening = TextEditingController();
  late bool theyOwe = widget.type == 'customer';

  @override
  void dispose() {
    for (final c in [name, phone, address, email, note, opening]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    final biz = ref.read(bizProvider);
    var id = widget.contact?.id ?? 0;
    final ok = await guard(context, () async {
      if (widget.contact == null) {
        final amt = parseNum(opening.text);
        id = await biz.contacts.create(
          type: widget.type,
          name: name.text,
          phone: phone.text,
          address: address.text,
          email: email.text,
          note: note.text,
          openingBalance: theyOwe ? amt : -amt,
        );
      } else {
        await biz.contacts.update(widget.contact!.id,
            name: name.text, phone: phone.text, address: address.text, email: email.text, note: note.text);
      }
    }, success: T.saved.s);
    if (ok && mounted) {
      Navigator.pop(context);
      if (widget.contact == null) context.go('${widget.type == 'customer' ? '/customers' : '/suppliers'}/$id');
    }
  }

  @override
  Widget build(BuildContext context) {
    final isCustomer = widget.type == 'customer';
    return AppDialog(
      title: widget.contact != null ? T.edit.s : (isCustomer ? T.addCustomer.s : T.addSupplier.s),
      icon: isCustomer ? Icons.person_add_alt_1_outlined : Icons.storefront_outlined,
      width: 520,
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(T.cancel.s)),
        FilledButton(onPressed: _save, child: Text(T.save.s)),
      ],
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        TextIn(controller: name, label: T.name.s, autofocus: true, icon: Icons.person_outline_rounded),
        const Gap(12),
        TextIn(controller: phone, label: T.phone.s, keyboard: TextInputType.phone, icon: Icons.phone_outlined),
        const Gap(12),
        TextIn(controller: address, label: '${T.address.s} (${T.optional.s})', icon: Icons.place_outlined),
        const Gap(12),
        FieldRow(children: [TextIn(controller: email, label: '${T.email.s} (${T.optional.s})'), TextIn(controller: note, label: T.noteOptional.s)]),
        if (widget.contact == null) ...[
          const Gap(16),
          Text(T.openingBalance.s, style: Txt.label),
          const Gap(8),
          Row(children: [
            Expanded(child: NumField(controller: opening, label: T.amount.s, prefix: '৳ ')),
            const Gap(12),
            SegmentedButton<bool>(
              showSelectedIcon: false,
              segments: [
                ButtonSegment(value: true, label: Text(T.theyOweYou.s)),
                ButtonSegment(value: false, label: Text(T.youOweThem.s)),
              ],
              selected: {theyOwe},
              onSelectionChanged: (s) => setState(() => theyOwe = s.first),
            ),
          ]),
        ],
      ]),
    );
  }
}
