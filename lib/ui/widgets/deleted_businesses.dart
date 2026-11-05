import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/i18n.dart';
import '../../core/theme.dart';
import '../../data/business_store.dart';
import '../../data/seed.dart';
import '../../state/app_state.dart';
import 'common.dart';

final deletedBusinessesProvider = FutureProvider<List<DeletedBusiness>>((ref) {
  ref.watch(appProvider);
  return BusinessStore.deletedBusinesses();
});

/// Lists businesses deleted in the last 30 days with a Restore button.
Future<void> showDeletedBusinesses(BuildContext context) =>
    showDialog(context: context, builder: (_) => const _DeletedDialog());

class _DeletedDialog extends ConsumerWidget {
  const _DeletedDialog();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final list = ref.watch(deletedBusinessesProvider);
    return AppDialog(
      title: T.recentlyDeleted.s,
      icon: Icons.restore_from_trash_outlined,
      width: 480,
      actions: [FilledButton(onPressed: () => Navigator.pop(context), child: Text(T.close.s))],
      child: AsyncView(list, builder: (items) {
        if (items.isEmpty) return Padding(padding: const EdgeInsets.all(12), child: Text(T.noData.s, style: Txt.small));
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(T.deletedKeepNote.s, style: Txt.small),
          const Gap(10),
          for (final d in items)
            Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
              decoration: BoxDecoration(color: C.paper, borderRadius: BorderRadius.circular(10)),
              child: Row(children: [
                Text(businessTypeById(d.type).icon, style: const TextStyle(fontSize: 20)),
                const Gap(10),
                Expanded(child: Cell2(d.name, T.deletedOn.f({'d': friendlyDate(d.deletedAt)}))),
                FilledButton.tonal(
                  onPressed: () async {
                    final ok = await guard(context, () => ref.read(appProvider.notifier).restoreDeleted(d.id));
                    if (ok && context.mounted) Navigator.pop(context);
                  },
                  child: Text(T.restoreBusiness.s),
                ),
              ]),
            ),
        ]);
      }),
    );
  }
}
