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
import '../../sync/sync_engine.dart';
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

/// The Drive permission request still waiting for Google's page, if any.
Future<bool>? _driveAsk;
int _driveAskId = 0;

/// Ask Google again to let BizKhata use Drive (on Windows the browser does it).
///
/// Tapping again while Google's page is still waited for (its tab was most
/// likely closed without finishing) drops that request and opens a fresh page,
/// so a closed tab never blocks Allow for the 5 minutes the wait lasts.
Future<bool> allowGoogleDrive(BuildContext context, WidgetRef ref) async {
  final earlier = _driveAsk;
  if (earlier != null) {
    ref.read(googleAuthProvider).cancelPendingConsent();
    await earlier;
  }
  final id = ++_driveAskId;
  final ask = () async {
    if (!Platform.isAndroid && context.mounted) toast(context, T.drAllowBrowser.s);
    try {
      await ref.read(driveAccessProvider.notifier).allow();
      if (context.mounted) toast(context, T.drAllowed.s);
      return true;
    } catch (e) {
      // Replaced by a newer tap: that one speaks for itself.
      if (id == _driveAskId && context.mounted) toast(context, errorText(e), error: true);
      return false;
    }
  }();
  _driveAsk = ask;
  try {
    return await ask;
  } finally {
    if (identical(_driveAsk, ask)) _driveAsk = null;
  }
}

/// The shops kept in the signed-in account's Google Drive. When Drive refuses,
/// [driveAccessProvider] hears of it, so the "Allow Google Drive" banner shows.
Future<List<CloudBusiness>> cloudShops(WidgetRef ref) async {
  final access = ref.read(driveAccessProvider.notifier);
  try {
    return await ref.read(cloudProvider).businesses();
  } on SyncException catch (e) {
    if (e.code == 'no_drive') access.recheck();
    rethrow;
  }
}

/// Pick one of the shops kept in this Google account and open it here.
Future<void> showOpenFromDrive(BuildContext context, WidgetRef ref) async {
  if (!await ensureGoogleSignIn(context, ref) || !context.mounted) return;
  await showDialog<void>(context: context, builder: (_) => const _CloudShopsDialog());
}

/// Shown while someone is signed in but Google Drive isn't allowed: the shops
/// then stay on this device until the Drive box is ticked on Google's page.
class DriveAccessBanner extends ConsumerWidget {
  /// Space above the banner, taken only while it shows.
  final double top;
  const DriveAccessBanner({super.key, this.top = 0});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (ref.watch(googleUserProvider) == null || ref.watch(driveAccessProvider)) return const SizedBox.shrink();
    return Padding(
      padding: EdgeInsets.only(top: top),
      child: Container(
        key: const ValueKey('drive-not-allowed'),
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        decoration: BoxDecoration(color: C.warnSoft, borderRadius: BorderRadius.circular(12)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Icon(Icons.cloud_off_outlined, size: 20, color: C.warn),
            const Gap(10),
            Expanded(child: Text(T.drNotAllowed.s, style: Txt.small.copyWith(color: C.ink))),
          ]),
          const Gap(10),
          Padding(
            padding: const EdgeInsets.only(left: 30),
            child: BusyButton(
              key: const ValueKey('allow-drive'),
              label: T.drAllow.s,
              icon: Icons.lock_open_rounded,
              onPressed: () async {
                await allowGoogleDrive(context, ref);
              },
            ),
          ),
        ]),
      ),
    );
  }
}

/// One row per shop kept in Google Drive; tapping one calls [onOpen].
class CloudShopTiles extends ConsumerWidget {
  final List<CloudBusiness> shops;
  final ValueChanged<CloudBusiness> onOpen;
  const CloudShopTiles({super.key, required this.shops, required this.onOpen});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final local = {for (final b in ref.watch(businessesProvider).value ?? const []) b.id};
    return Column(children: [
      for (final b in shops)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Material(
            color: C.paper,
            borderRadius: BorderRadius.circular(12),
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () => onOpen(b),
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
  }
}

class _CloudShopsDialog extends ConsumerStatefulWidget {
  const _CloudShopsDialog();
  @override
  ConsumerState<_CloudShopsDialog> createState() => _CloudShopsDialogState();
}

class _CloudShopsDialogState extends ConsumerState<_CloudShopsDialog> {
  Future<List<CloudBusiness>>? shops;
  String? opening;

  Future<void> _open(CloudBusiness b) async {
    final access = ref.read(driveAccessProvider.notifier);
    setState(() => opening = b.name);
    try {
      await ref.read(appProvider.notifier).openFromCloud(b, ref.read(cloudProvider));
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (e is SyncException && e.code == 'no_drive') access.recheck();
      if (!mounted) return;
      setState(() => opening = null);
      toast(context, errorText(e), error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = ref.watch(googleUserProvider);
    final allowed = ref.watch(driveAccessProvider);
    // Without Drive there is nothing to list: the banner asks for it instead,
    // and the list loads once it is allowed.
    if (allowed) {
      shops ??= cloudShops(ref);
    } else {
      shops = null;
    }
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
              if (!allowed)
                const DriveAccessBanner()
              else
                FutureBuilder<List<CloudBusiness>>(
                  future: shops,
                  builder: (_, snap) {
                    if (snap.hasError) return Text(errorText(snap.error!), style: Txt.small.copyWith(color: C.outRed));
                    final list = snap.data;
                    if (list == null) return const Padding(padding: EdgeInsets.all(20), child: Loading());
                    if (list.isEmpty) return Text(T.cloudNoShops.s, style: Txt.body);
                    return CloudShopTiles(shops: list, onOpen: _open);
                  },
                ),
            ]),
    );
  }
}

/// Small sync indicator for the sidebar: hidden when the shop doesn't sync,
/// a warning while the signed-in account hasn't allowed Google Drive.
class CloudStatusChip extends ConsumerWidget {
  const CloudStatusChip({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final st = ref.watch(cloudSyncProvider);
    if (ref.watch(googleUserProvider) != null && !ref.watch(driveAccessProvider)) {
      return _SideChip(
        icon: Icons.cloud_off_outlined,
        iconColor: C.marigold,
        label: T.drChipNotAllowed.s,
        tip: T.drNotAllowed.s,
        // One tap asks Google again, as the banner's button does; staff
        // can't change the owner's account.
        onTap: () async {
          if (ref.read(actorProvider).isOwner) await allowGoogleDrive(context, ref);
        },
      );
    }
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
    return _SideChip(
      icon: icon,
      iconColor: st.error != null ? const Color(0xFFFFB4A6) : null,
      label: label,
      tip: tip.isEmpty ? T.cloudOn.s : tip,
      trailing: st.pending > 0 ? number(st.pending) : null,
      onTap: () {
        if (ref.read(actorProvider).isOwner) {
          context.go('/settings');
        } else {
          ref.read(cloudSyncProvider.notifier).syncNow(quiet: true);
        }
      },
    );
  }
}

class _SideChip extends StatelessWidget {
  final IconData icon;
  final Color? iconColor;
  final String label;
  final String tip;
  final String? trailing;
  final VoidCallback onTap;
  const _SideChip({required this.icon, this.iconColor, required this.label, required this.tip, this.trailing, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final faint = Colors.white.withValues(alpha: 0.7);
    return Tooltip(
      message: tip,
      child: InkWell(
        borderRadius: BorderRadius.circular(9),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 8, 6),
          child: Row(children: [
            Icon(icon, size: 17, color: iconColor ?? faint),
            const SizedBox(width: 10),
            Expanded(
              child: Text(label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontFamily: kBody, fontSize: 12.5, color: faint)),
            ),
            if (trailing != null) Text(trailing!, style: TextStyle(fontFamily: kBody, fontSize: 11.5, color: faint)),
          ]),
        ),
      ),
    );
  }
}
