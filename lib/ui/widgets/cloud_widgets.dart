import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/format.dart';
import '../../core/i18n.dart';
import '../../core/theme.dart';
import '../../data/seed.dart';
import '../../state/app_state.dart';
import '../../state/cloud_state.dart';
import '../../sync/cloud_sync.dart';
import '../../sync/google_auth.dart';
import 'common.dart';

/// Sign in (if needed) and run [action]; on Windows the browser does the sign-in.
Future<bool> ensureGoogleSignIn(BuildContext context, WidgetRef ref) async {
  if (!GoogleConfig.ready) {
    toast(context, T.cloudNotReady.s, error: true);
    return false;
  }
  if (ref.read(googleUserProvider) != null) return true;
  if (!Platform.isAndroid) toast(context, T.signInBrowser.s);
  return guard(context, () => ref.read(googleUserProvider.notifier).signIn());
}

/// Pick one of the shops kept in this Google account and open it here.
Future<void> showOpenFromDrive(BuildContext context, WidgetRef ref) async {
  if (!await ensureGoogleSignIn(context, ref) || !context.mounted) return;
  await showDialog<void>(context: context, builder: (_) => const _CloudShopsDialog());
}

class _CloudShopsDialog extends ConsumerStatefulWidget {
  const _CloudShopsDialog();
  @override
  ConsumerState<_CloudShopsDialog> createState() => _CloudShopsDialogState();
}

class _CloudShopsDialogState extends ConsumerState<_CloudShopsDialog> {
  late final Future<List<CloudBusiness>> shops = ref.read(cloudProvider).businesses();
  String? opening;

  Future<void> _open(CloudBusiness b) async {
    setState(() => opening = b.name);
    try {
      await ref.read(appProvider.notifier).openFromCloud(b, ref.read(cloudProvider));
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      setState(() => opening = null);
      toast(context, errorText(e), error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final local = {for (final b in ref.watch(businessesProvider).value ?? const []) b.id};
    final user = ref.watch(googleUserProvider);
    return AppDialog(
      title: T.openFromDrive.s,
      icon: Icons.cloud_download_outlined,
      width: 500,
      actions: [if (opening == null) TextButton(onPressed: () => Navigator.pop(context), child: Text(T.close.s))],
      child: opening != null
          ? Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Column(children: [
                const CircularProgressIndicator(),
                const Gap(14),
                Text(T.cloudOpening.f({'x': opening}), style: Txt.body),
              ]),
            )
          : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              if (user != null) Text(T.signedInAs.f({'x': user.email}), style: Txt.small),
              const Gap(10),
              FutureBuilder<List<CloudBusiness>>(
                future: shops,
                builder: (_, snap) {
                  if (snap.hasError) return Text(errorText(snap.error!), style: Txt.small.copyWith(color: C.outRed));
                  final list = snap.data;
                  if (list == null) return const Padding(padding: EdgeInsets.all(20), child: Loading());
                  if (list.isEmpty) return Text(T.cloudNoShops.s, style: Txt.body);
                  return Column(children: [
                    for (final b in list)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Material(
                          color: C.paper,
                          borderRadius: BorderRadius.circular(12),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(12),
                            onTap: () => _open(b),
                            child: Padding(
                              padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
                              child: Row(children: [
                                Text(businessTypeById(b.type).icon, style: const TextStyle(fontSize: 22)),
                                const Gap(12),
                                Expanded(
                                  child: Cell2(
                                      b.name,
                                      T.cloudShopInfo.f({
                                        'n': number(b.devices.length),
                                        't': b.updated == null ? '—' : friendlyDate(b.updated!.toLocal()),
                                      })),
                                ),
                                if (local.contains(b.id))
                                  Pill(T.cloudOnThisDevice.s, tone: Tone.good)
                                else
                                  const Icon(Icons.chevron_right_rounded, color: C.ink3),
                              ]),
                            ),
                          ),
                        ),
                      ),
                  ]);
                },
              ),
            ]),
    );
  }
}

/// Small sync indicator for the sidebar (hidden when the shop doesn't sync).
class CloudStatusChip extends ConsumerWidget {
  const CloudStatusChip({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final st = ref.watch(cloudSyncProvider);
    if (!st.on) return const SizedBox.shrink();
    final (icon, label) = st.busy
        ? (Icons.sync_rounded, T.cloudSyncing.s)
        : st.paused
            ? (Icons.pause_circle_outline_rounded, T.cloudResume.s)
            : st.error != null
                ? (Icons.cloud_off_outlined, st.lastSync == null ? T.cloudNever.s : T.cloudSynced.f({'t': timeShort(st.lastSync!)}))
                : (Icons.cloud_done_outlined, st.lastSync == null ? T.cloudNever.s : T.cloudSynced.f({'t': timeShort(st.lastSync!)}));
    final tip = [
      if (st.error != null) errorText(st.error!),
      if (st.pending > 0) T.cloudPending.f({'n': number(st.pending)}),
    ].join('\n');
    final faint = Colors.white.withValues(alpha: 0.7);
    return Tooltip(
      message: tip.isEmpty ? T.cloudOn.s : tip,
      child: InkWell(
        borderRadius: BorderRadius.circular(9),
        onTap: () {
          if (ref.read(actorProvider).isOwner) {
            context.go('/settings');
          } else {
            ref.read(cloudSyncProvider.notifier).syncNow(quiet: true);
          }
        },
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 8, 6),
          child: Row(children: [
            Icon(icon, size: 17, color: st.error != null ? const Color(0xFFFFB4A6) : faint),
            const SizedBox(width: 10),
            Expanded(
              child: Text(label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontFamily: kBody, fontSize: 12.5, color: faint)),
            ),
            if (st.pending > 0)
              Text(number(st.pending), style: TextStyle(fontFamily: kBody, fontSize: 11.5, color: faint)),
          ]),
        ),
      ),
    );
  }
}
