import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/i18n.dart';
import '../../core/theme.dart';
import '../../core/util.dart';
import '../../data/biz.dart';
import '../../state/app_state.dart';
import '../widgets/common.dart';

final _expenses = StreamProvider.autoDispose.family<List<Expense>, (DateRange, String?)>(
    (ref, a) => ref.watch(bizProvider).expenses.watchExpenses(range: a.$1, category: a.$2));
final _byCat = StreamProvider.autoDispose.family<List<({String category, double total})>, DateRange>(
    (ref, r) => ref.watch(bizProvider).expenses.watchByCategory(r));
final expenseCatsProvider = StreamProvider.autoDispose((ref) => ref.watch(bizProvider).expenses.watchCategories());

class ExpensesScreen extends ConsumerStatefulWidget {
  const ExpensesScreen({super.key});
  @override
  ConsumerState<ExpensesScreen> createState() => _ExpensesScreenState();
}

class _ExpensesScreenState extends ConsumerState<ExpensesScreen> {
  RangeSelection range = RangeSelection.of(RangePreset.thisMonth);
  String? category;

  @override
  Widget build(BuildContext context) {
    final rows = ref.watch(_expenses((range.range, category)));
    final cats = ref.watch(_byCat(range.range)).value ?? const [];
    final accounts = {for (final a in ref.watch(accountsProvider).value ?? const <Account>[]) a.id: a.name};
    final total = cats.fold<double>(0, (s, c) => s + c.total);
    final maxCat = cats.isEmpty ? 1.0 : cats.first.total;
    final biz = ref.watch(bizProvider);

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      PageHeader(
        title: T.expenses.s,
        subtitle: range.label,
        actions: [
          RangeButton(value: range, onChanged: (r) => setState(() => range = r)),
          FilledButton.icon(
            onPressed: () => showExpenseDialog(context),
            icon: const Icon(Icons.add_rounded, size: 19),
            label: Text(T.addExpense.s),
          ),
        ],
      ),
      // Narrow screens: category totals as a strip of chips above the list.
      if (context.isCompact)
        SizedBox(
          height: 46,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: EdgeInsets.fromLTRB(context.gutter, 0, context.gutter, 8),
            children: [
              Center(child: Pill('${T.totalExpense.s}: ${money(total)}', tone: Tone.bad)),
              for (final c in cats)
                Padding(
                  padding: const EdgeInsets.only(left: 6),
                  child: ChoiceChip(
                    label: Text('${c.category} · ${money(c.total)}'),
                    selected: category == c.category,
                    onSelected: (v) => setState(() => category = v ? c.category : null),
                  ),
                ),
            ],
          ),
        ),
      Expanded(
        child: Padding(
          padding: EdgeInsets.fromLTRB(context.gutter, 0, context.gutter, 24),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
              flex: 3,
              child: Container(
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(color: C.card, borderRadius: BorderRadius.circular(14), border: Border.all(color: C.line)),
                child: Column(children: [
                  TableHead([
                    Col(T.date.s, flex: 3),
                    Col(T.expenseCategory.s, flex: 4),
                    Col(T.paidFrom.s, flex: 3),
                    Col(T.amount.s, flex: 3, align: TextAlign.right),
                    const Col('', flex: 1),
                  ]),
                  Expanded(
                    child: AsyncView(rows, builder: (list) {
                      if (list.isEmpty) {
                        return EmptyState(
                          icon: Icons.receipt_outlined,
                          text: T.noData.s,
                          action: OutlinedButton.icon(
                            onPressed: () => showExpenseDialog(context),
                            icon: const Icon(Icons.add, size: 18),
                            label: Text(T.addExpense.s),
                          ),
                        );
                      }
                      return ListView.builder(
                        itemCount: list.length,
                        itemBuilder: (_, i) {
                          final e = list[i];
                          return TableRowX(
                            cols: const [Col('', flex: 3), Col('', flex: 4), Col('', flex: 3), Col('', flex: 3, align: TextAlign.right), Col('', flex: 1, align: TextAlign.right)],
                            cells: [
                              Text(friendlyDate(e.date), style: Txt.small),
                              Cell2(e.category, e.note),
                              Text(accounts[e.accountId] ?? '—', style: Txt.small),
                              MoneyText(e.amount, tone: Tone.bad),
                              e.refType == 'sale'
                                  ? const SizedBox()
                                  : IconButton(
                                      tooltip: T.delete.s,
                                      iconSize: 18,
                                      onPressed: () async {
                                        final ok = await confirmDialog(context, title: T.areYouSure.s, danger: true, confirmLabel: T.delete.s);
                                        if (ok && context.mounted) await guard(context, () => biz.expenses.delete(e.id), success: T.deleted.s);
                                      },
                                      icon: const Icon(Icons.delete_outline_rounded, color: C.ink3),
                                    ),
                            ],
                          );
                        },
                      );
                    }),
                  ),
                ]),
              ),
            ),
            if (!context.isCompact) ...[
            const Gap(16),
            SizedBox(
              width: 340,
              child: Panel(
                title: T.totalExpense.s,
                trailing: Text(money(total), style: Txt.display(20, color: C.outRed)),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  if (category != null)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: InputChip(label: Text(category!), onDeleted: () => setState(() => category = null)),
                    ),
                  for (final c in cats)
                    InkWell(
                      onTap: () => setState(() => category = c.category),
                      borderRadius: BorderRadius.circular(8),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 7, horizontal: 2),
                        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                          Row(children: [
                            Expanded(child: Text(c.category, style: Txt.body.copyWith(fontWeight: category == c.category ? FontWeight.w700 : FontWeight.w400))),
                            Text(money(c.total), style: Txt.num),
                          ]),
                          const Gap(5),
                          ClipRRect(
                            borderRadius: BorderRadius.circular(3),
                            child: LinearProgressIndicator(
                              value: c.total / maxCat,
                              minHeight: 6,
                              backgroundColor: C.paper2,
                              color: C.outRed.withValues(alpha: 0.75),
                            ),
                          ),
                        ]),
                      ),
                    ),
                  if (cats.isEmpty) Text(T.noData.s, style: Txt.small),
                ]),
              ),
            ),
            ],
          ]),
        ),
      ),
    ]);
  }
}

Future<void> showExpenseDialog(BuildContext context) => showDialog(context: context, builder: (_) => const _ExpenseDialog());

class _ExpenseDialog extends ConsumerStatefulWidget {
  const _ExpenseDialog();
  @override
  ConsumerState<_ExpenseDialog> createState() => _ExpenseDialogState();
}

class _ExpenseDialogState extends ConsumerState<_ExpenseDialog> {
  final amount = TextEditingController();
  final note = TextEditingController();
  final category = TextEditingController();
  int? accountId;
  DateTime date = DateTime.now();

  @override
  void initState() {
    super.initState();
    Future.microtask(() async {
      final id = await ref.read(bizProvider).cash.defaultCashAccount();
      if (mounted) setState(() => accountId = id);
    });
  }

  @override
  void dispose() {
    amount.dispose();
    note.dispose();
    category.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final now = DateTime.now();
    final ok = await guard(context, () async {
      await ref.read(bizProvider).expenses.add(
            category: category.text,
            amount: parseNum(amount.text),
            accountId: accountId,
            note: note.text.trim().isEmpty ? null : note.text.trim(),
            date: DateTime(date.year, date.month, date.day, now.hour, now.minute),
          );
    }, success: T.saved.s);
    if (ok && mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final cats = ref.watch(expenseCatsProvider).value ?? const <ExpenseCategory>[];
    return AppDialog(
      title: T.addExpense.s,
      icon: Icons.receipt_outlined,
      tone: Tone.bad,
      width: 500,
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(T.cancel.s)),
        FilledButton(onPressed: _save, child: Text(T.save.s)),
      ],
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(T.expenseCategory.s, style: Txt.label),
        const Gap(8),
        Wrap(spacing: 6, runSpacing: 6, children: [
          for (final c in cats.where((c) => c.name != 'Courier charge'))
            ChoiceChip(
              label: Text(c.name),
              selected: category.text == c.name,
              onSelected: (_) => setState(() => category.text = c.name),
            ),
        ]),
        const Gap(10),
        TextIn(controller: category, label: '${T.expenseCategory.s} (${isBangla ? 'নতুনও লিখতে পারেন' : 'or type a new one'})', onChanged: (_) => setState(() {})),
        const Gap(14),
        TextField(
          controller: amount,
          autofocus: true,
          inputFormatters: [NumberInputFormatter()],
          style: Txt.display(26, color: C.outRed),
          decoration: InputDecoration(labelText: T.amount.s, prefixText: '৳ '),
          onSubmitted: (_) => _save(),
        ),
        const Gap(14),
        Text(T.paidFrom.s, style: Txt.label),
        const Gap(8),
        AccountChips(value: accountId, onChanged: (v) => setState(() => accountId = v), includeCourier: true),
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
