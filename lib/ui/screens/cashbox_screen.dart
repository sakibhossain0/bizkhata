import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/format.dart';
import '../../core/i18n.dart';
import '../../core/theme.dart';
import '../../core/util.dart';
import '../../data/biz.dart';
import '../../state/app_state.dart';
import '../widgets/common.dart';
import '../widgets/day_end.dart';

final _balances = StreamProvider.autoDispose((ref) => ref.watch(bizProvider).cash.watchBalances());
final _txns = StreamProvider.autoDispose.family<List<CashTxn>, (int?, DateRange)>(
    (ref, a) => ref.watch(bizProvider).cash.watchTxns(accountId: a.$1, range: a.$2));
final _flow = StreamProvider.autoDispose.family<({double cashIn, double cashOut}), (int?, DateRange)>(
    (ref, a) => ref.watch(bizProvider).cash.watchFlow(accountId: a.$1, range: a.$2));

const accountKinds = ['cash', 'mobile', 'bank', 'card', 'courier', 'other'];

class CashboxScreen extends ConsumerStatefulWidget {
  const CashboxScreen({super.key});
  @override
  ConsumerState<CashboxScreen> createState() => _CashboxScreenState();
}

class _CashboxScreenState extends ConsumerState<CashboxScreen> {
  int? accountId;
  RangeSelection range = RangeSelection.of(RangePreset.thisMonth);

  @override
  Widget build(BuildContext context) {
    final balances = ref.watch(_balances).value ?? const <AccountBalance>[];
    final total = balances.fold<double>(0, (s, a) => s + a.balance);
    final names = {for (final b in balances) b.account.id: b.account.name};
    final txns = ref.watch(_txns((accountId, range.range)));
    final flow = ref.watch(_flow((accountId, range.range))).value;
    final biz = ref.watch(bizProvider);
    final hasCourier = balances.any((b) => b.account.kind == 'courier' && b.balance > 0);

    return ListView(padding: const EdgeInsets.only(bottom: 28), children: [
      PageHeader(
        title: T.cashbox.s,
        subtitle: '${T.allAccounts.s}: ${money(total)}',
        actions: [
          OutlinedButton.icon(
            onPressed: () => showDayEnd(context),
            icon: const Icon(Icons.summarize_outlined, size: 18),
            label: Text(T.dayEnd.s),
          ),
          OutlinedButton.icon(
            onPressed: () => _manual(context, cashIn: false),
            icon: const Icon(Icons.north_east_rounded, size: 18, color: C.outRed),
            label: Text(T.cashOut.s),
          ),
          OutlinedButton.icon(
            onPressed: () => _manual(context, cashIn: true),
            icon: const Icon(Icons.south_west_rounded, size: 18, color: C.inGreen),
            label: Text(T.cashIn.s),
          ),
          FilledButton.icon(
            onPressed: () => _transfer(context),
            icon: const Icon(Icons.swap_horiz_rounded, size: 19),
            label: Text(T.transfer.s),
          ),
        ],
      ),
      // Wrap (not a sideways list) so every account is visible without horizontal scrolling.
      Padding(
        padding: EdgeInsets.symmetric(horizontal: context.gutter),
        child: Wrap(
          runSpacing: 12,
          children: [
            _AccountCard(
              name: T.allAccounts.s,
              kind: 'all',
              balance: total,
              selected: accountId == null,
              onTap: () => setState(() => accountId = null),
            ),
            for (final b in balances)
              _AccountCard(
                name: b.account.name,
                kind: b.account.kind,
                balance: b.balance,
                selected: accountId == b.account.id,
                onTap: () => setState(() => accountId = b.account.id),
                onEdit: () => showAccountDialog(context, ref, account: b.account),
              ),
            _AddCard(onTap: () => showAccountDialog(context, ref)),
          ],
        ),
      ),
      if (hasCourier)
        Container(
          margin: EdgeInsets.fromLTRB(context.gutter, 12, context.gutter, 0),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(color: C.infoSoft, borderRadius: BorderRadius.circular(10)),
          child: Row(children: [
            const Icon(Icons.info_outline_rounded, size: 18, color: C.info),
            const Gap(8),
            Expanded(child: Text(T.courierPayoutHint.s, style: Txt.small.copyWith(color: C.info))),
          ]),
        ),
      Padding(
        padding: EdgeInsets.fromLTRB(context.gutter, 18, context.gutter, 10),
        child: Row(children: [
          Text(T.transactions.s, style: Txt.display(19)),
          const Gap(12),
          if (flow != null) ...[
            Pill('${T.moneyIn.s} ${money(flow.cashIn)}', tone: Tone.good),
            const Gap(6),
            Pill('${T.moneyOut.s} ${money(flow.cashOut)}', tone: Tone.bad),
          ],
          const Spacer(),
          RangeButton(value: range, onChanged: (r) => setState(() => range = r)),
        ]),
      ),
      Container(
        margin: EdgeInsets.symmetric(horizontal: context.gutter),
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(color: C.card, borderRadius: BorderRadius.circular(14), border: Border.all(color: C.line)),
        child: Column(children: [
          TableHead([
            Col(T.date.s, flex: 3),
            Col(T.details.s, flex: 5),
            Col(T.account.s, flex: 3),
            Col(T.moneyIn.s, flex: 3, align: TextAlign.right),
            Col(T.moneyOut.s, flex: 3, align: TextAlign.right),
            const Col('', flex: 1),
          ]),
          AsyncView(txns, builder: (list) {
            if (list.isEmpty) return SizedBox(height: 200, child: EmptyState(icon: Icons.account_balance_wallet_outlined, text: T.noData.s));
            return Column(children: [
              for (final t in list)
                TableRowX(
                  cols: const [Col('', flex: 3), Col('', flex: 5), Col('', flex: 3), Col('', flex: 3, align: TextAlign.right), Col('', flex: 3, align: TextAlign.right), Col('', flex: 1, align: TextAlign.right)],
                  onTap: t.refType == 'sale' && t.refId != null ? () => context.go('/sales/${t.refId}') : null,
                  cells: [
                    Text(friendlyDate(t.date), style: Txt.small),
                    Cell2(tKey('src', t.source), t.note, Txt.body),
                    Text(names[t.accountId] ?? '—', style: Txt.small),
                    Text(t.direction > 0 ? money(t.amount) : '', style: Txt.num.copyWith(color: C.inGreen)),
                    Text(t.direction < 0 ? money(t.amount) : '', style: Txt.num.copyWith(color: C.outRed)),
                    const {'manual_in', 'manual_out', 'transfer'}.contains(t.source)
                        ? IconButton(
                            tooltip: T.delete.s,
                            iconSize: 17,
                            onPressed: () async {
                              final ok = await confirmDialog(context, title: T.areYouSure.s, danger: true, confirmLabel: T.delete.s);
                              if (ok && context.mounted) await guard(context, () => biz.cash.deleteManual(t.id), success: T.deleted.s);
                            },
                            icon: const Icon(Icons.delete_outline_rounded, color: C.ink3),
                          )
                        : const SizedBox(),
                  ],
                ),
            ]);
          }),
        ]),
      ),
    ]);
  }

  Future<void> _manual(BuildContext context, {required bool cashIn}) async {
    final amount = TextEditingController();
    final note = TextEditingController();
    int? acc = accountId ?? await ref.read(bizProvider).cash.defaultCashAccount();
    if (!context.mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AppDialog(
          title: cashIn ? T.cashIn.s : T.cashOut.s,
          icon: cashIn ? Icons.south_west_rounded : Icons.north_east_rounded,
          tone: cashIn ? Tone.good : Tone.bad,
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(T.cancel.s)),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(T.save.s)),
          ],
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(cashIn ? T.cashInHint.s : T.cashOutHint.s, style: Txt.small),
            const Gap(12),
            TextField(
              controller: amount,
              autofocus: true,
              inputFormatters: [NumberInputFormatter()],
              style: Txt.display(26, color: cashIn ? C.inGreen : C.outRed),
              decoration: InputDecoration(labelText: T.amount.s, prefixText: '৳ '),
            ),
            const Gap(12),
            AccountChips(value: acc, includeCourier: true, onChanged: (v) => setD(() => acc = v)),
            const Gap(12),
            TextIn(controller: note, label: T.noteOptional.s),
          ]),
        ),
      ),
    );
    if (ok == true && acc != null && context.mounted) {
      await guard(
        context,
        () => ref.read(bizProvider).cash.manual(accountId: acc!, cashIn: cashIn, amount: parseNum(amount.text), note: note.text.trim().isEmpty ? null : note.text.trim()),
        success: T.saved.s,
      );
    }
    amount.dispose();
    note.dispose();
  }

  Future<void> _transfer(BuildContext context) async {
    final amount = TextEditingController();
    final note = TextEditingController();
    final accs = await ref.read(bizProvider).cash.accounts();
    if (!context.mounted || accs.length < 2) return;
    int from = accs.firstWhere((a) => a.kind == 'courier', orElse: () => accs.first).id;
    int to = accs.firstWhere((a) => a.id != from).id;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AppDialog(
          title: T.transfer.s,
          icon: Icons.swap_horiz_rounded,
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(T.cancel.s)),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(T.transfer.s)),
          ],
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(T.fromAccount.s, style: Txt.label),
            const Gap(6),
            AccountChips(value: from, includeCourier: true, onChanged: (v) => setD(() => from = v)),
            const Gap(14),
            Text(T.toAccount.s, style: Txt.label),
            const Gap(6),
            AccountChips(value: to, includeCourier: true, onChanged: (v) => setD(() => to = v)),
            const Gap(14),
            NumField(controller: amount, label: T.amount.s, prefix: '৳ ', autofocus: true),
            const Gap(12),
            TextIn(controller: note, label: T.noteOptional.s),
          ]),
        ),
      ),
    );
    if (ok == true && context.mounted) {
      await guard(
        context,
        () => ref.read(bizProvider).cash.transfer(fromId: from, toId: to, amount: parseNum(amount.text), note: note.text.trim().isEmpty ? null : note.text.trim()),
        success: T.saved.s,
      );
    }
    amount.dispose();
    note.dispose();
  }
}

class _AccountCard extends StatelessWidget {
  final String name;
  final String kind;
  final double balance;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback? onEdit;
  const _AccountCard({required this.name, required this.kind, required this.balance, required this.selected, required this.onTap, this.onEdit});

  @override
  Widget build(BuildContext context) {
    final dark = selected;
    return Padding(
      padding: const EdgeInsets.only(right: 12),
      child: Material(
        color: dark ? C.brand : C.card,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          onTap: onTap,
          onLongPress: onEdit,
          borderRadius: BorderRadius.circular(14),
          child: Container(
            width: 210,
            height: 128,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(14), border: Border.all(color: dark ? C.brand : C.line)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Icon(kind == 'all' ? Icons.account_balance_wallet_rounded : accountIcon(kind), size: 18, color: dark ? C.marigold : C.ink2),
                const Gap(8),
                Expanded(
                  child: Text(name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Txt.strong.copyWith(color: dark ? Colors.white : C.ink)),
                ),
                if (onEdit != null)
                  InkWell(
                    onTap: onEdit,
                    child: Icon(Icons.edit_outlined, size: 15, color: dark ? Colors.white60 : C.ink3),
                  ),
              ]),
              const Spacer(),
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(money(balance), style: Txt.display(24, color: dark ? Colors.white : (balance < 0 ? C.outRed : C.ink))),
              ),
              Text(kind == 'all' ? T.balance.s : tKey('ak', kind),
                  style: Txt.tiny.copyWith(color: dark ? Colors.white60 : C.ink3)),
            ]),
          ),
        ),
      ),
    );
  }
}

class _AddCard extends StatelessWidget {
  final VoidCallback onTap;
  const _AddCard({required this.onTap});
  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        width: 150,
        height: 128,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: C.line, width: 1.5),
          color: C.paper,
        ),
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          const Icon(Icons.add_rounded, color: C.brand),
          const Gap(4),
          Text(T.addAccount.s, style: Txt.strong.copyWith(color: C.brand)),
        ]),
      ),
    );
  }
}

Future<void> showAccountDialog(BuildContext context, WidgetRef ref, {Account? account}) async {
  final name = TextEditingController(text: account?.name ?? '');
  final opening = TextEditingController(text: account == null || account.opening == 0 ? '' : '${account.opening}');
  var kind = account?.kind ?? 'mobile';
  final ok = await showDialog<String>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setD) => AppDialog(
        title: account == null ? T.addAccount.s : T.edit.s,
        icon: Icons.account_balance_wallet_outlined,
        actions: [
          if (account != null && account.kind != 'cash')
            TextButton(
              style: TextButton.styleFrom(foregroundColor: C.outRed),
              onPressed: () => Navigator.pop(ctx, 'hide'),
              child: Text(T.hideAccount.s),
            ),
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(T.cancel.s)),
          FilledButton(onPressed: () => Navigator.pop(ctx, 'save'), child: Text(T.save.s)),
        ],
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          TextIn(controller: name, label: T.name.s, autofocus: true, hint: 'bKash Personal, DBBL, Rocket…'),
          const Gap(12),
          Wrap(spacing: 6, runSpacing: 6, children: [
            for (final k in accountKinds)
              ChoiceChip(
                avatar: Icon(accountIcon(k), size: 16),
                label: Text(tKey('ak', k)),
                selected: kind == k,
                onSelected: (_) => setD(() => kind = k),
              ),
          ]),
          const Gap(12),
          NumField(controller: opening, label: T.openingAmount.s, prefix: '৳ '),
        ]),
      ),
    ),
  );
  if (!context.mounted) return;
  final cash = ref.read(bizProvider).cash;
  if (ok == 'save') {
    await guard(context, () async {
      if (account == null) {
        await cash.createAccount(name.text, kind: kind, opening: parseNum(opening.text));
      } else {
        if (name.text.trim().isEmpty) throw BizException('name_required');
        await cash.updateAccount(account.id, name: name.text, kind: kind, opening: parseNum(opening.text));
      }
    }, success: T.saved.s);
  } else if (ok == 'hide' && account != null) {
    await guard(context, () => cash.setAccountActive(account.id, false));
  }
  name.dispose();
  opening.dispose();
}
