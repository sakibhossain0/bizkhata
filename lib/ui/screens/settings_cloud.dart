import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/i18n.dart';
import '../../core/theme.dart';
import '../../state/app_state.dart';
import '../../state/cloud_state.dart';
import '../../sync/cloud_sync.dart';
import '../../sync/google_auth.dart';
import '../widgets/cloud_widgets.dart';
import '../widgets/common.dart';

/// Settings → Google Drive & devices (owner only).
class CloudSettings extends ConsumerStatefulWidget {
  const CloudSettings({super.key});
  @override
  ConsumerState<CloudSettings> createState() => _CloudSettingsState();
}

class _CloudSettingsState extends ConsumerState<CloudSettings> {
  Future<List<CloudDevice>>? devices;
  String myId = '';
  String tag = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final ctrl = ref.read(cloudSyncProvider.notifier);
    final id = await ctrl.deviceId();
    final t = await ref.read(bizProvider).settings.deviceTag();
    if (!mounted) return;
    setState(() {
      myId = id;
      tag = t;
      devices = ref.read(cloudSyncProvider).on && ref.read(googleUserProvider) != null ? ctrl.devices() : null;
    });
  }

  Future<void> _enable() async {
    if (!await ensureGoogleSignIn(context, ref) || !mounted) return;
    final ok = await guard(context, () => ref.read(cloudSyncProvider.notifier).enable(), success: T.cloudOn.s);
    if (ok) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final user = ref.watch(googleUserProvider);
    final st = ref.watch(cloudSyncProvider);
    final ctrl = ref.read(cloudSyncProvider.notifier);
    final title = Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(T.cloudTitle.s, style: Txt.display(22)),
        const Gap(4),
        Text(T.cloudHint.s, style: Txt.small),
      ]),
    );
    if (!GoogleConfig.ready) {
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        title,
        Panel(child: Text(T.cloudNotReady.s, style: Txt.body)),
      ]);
    }

    final status = st.busy
        ? T.cloudSyncing.s
        : st.lastSync == null
            ? T.cloudNever.s
            : T.cloudSynced.f({'t': friendlyDate(st.lastSync!)});

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      title,
      Panel(
        child: user == null
            ? AdaptiveRow(children: [
                const Icon(Icons.account_circle_outlined, size: 30, color: C.ink3),
                const Gap(12),
                Expanded(child: Text(T.openFromDriveHint.s, style: Txt.small)),
                const Gap(12),
                BusyButton(
                  label: T.signInGoogle.s,
                  icon: Icons.login_rounded,
                  onPressed: () async {
                    await ensureGoogleSignIn(context, ref);
                    await _load();
                  },
                ),
              ])
            : Row(children: [
                Avatar(user.name ?? user.email, size: 40),
                const Gap(12),
                Expanded(child: Cell2(user.name ?? user.email, user.email)),
                TextButton(
                  onPressed: () async {
                    final ok = await confirmDialog(context, title: T.signOutGoogle.s);
                    if (ok && context.mounted) {
                      await guard(context, () => ref.read(googleUserProvider.notifier).signOut());
                      await _load();
                    }
                  },
                  child: Text(T.signOutGoogle.s),
                ),
              ]),
      ),
      const Gap(16),
      Panel(
        child: !st.on
            ? Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Text(T.cloudEnableHint.s, style: Txt.body),
                const Gap(14),
                Align(
                  alignment: Alignment.centerLeft,
                  child: BusyButton(label: T.cloudEnable.s, icon: Icons.cloud_upload_outlined, onPressed: _enable),
                ),
              ])
            : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Row(children: [
                  Icon(st.error == null ? Icons.cloud_done_rounded : Icons.cloud_off_rounded,
                      size: 30, color: st.error == null ? C.inGreen : C.warn),
                  const Gap(12),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(T.cloudOn.s, style: Txt.strong),
                      Text(status, style: Txt.small),
                      if (st.pending > 0) Text(T.cloudPending.f({'n': number(st.pending)}), style: Txt.small),
                      if (st.error != null)
                        Text(errorText(st.error!), style: Txt.small.copyWith(color: C.outRed)),
                    ]),
                  ),
                  BusyButton(
                    label: T.cloudSyncNow.s,
                    icon: Icons.sync_rounded,
                    onPressed: () async {
                      await guard(context, () => ctrl.syncNow());
                      await _load();
                    },
                  ),
                ]),
                if (tag.isNotEmpty) ...[
                  const Gap(10),
                  Text(T.cloudInvoiceTag.f({'x': tag}), style: Txt.small),
                ],
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: st.paused,
                  onChanged: (v) => guard(context, () => ctrl.setPaused(v)),
                  title: Text(T.cloudPause.s, style: Txt.body),
                  subtitle: st.paused ? Text(T.cloudPaused.s, style: Txt.tiny) : null,
                ),
                Text(T.cloudHowItWorks.s, style: Txt.tiny),
              ]),
      ),
      if (devices != null) ...[
        const Gap(16),
        Panel(
          title: T.cloudDevices.s,
          child: FutureBuilder<List<CloudDevice>>(
            future: devices,
            builder: (_, snap) {
              final list = snap.data;
              if (snap.hasError) return Text(errorText(snap.error!), style: Txt.small);
              if (list == null) return const Loading();
              return Column(children: [
                for (final d in list)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(children: [
                      Avatar(d.tag, size: 34, tone: d.id == myId ? Tone.brand : Tone.neutral),
                      const Gap(12),
                      Expanded(
                        child: Cell2(
                          d.id == myId ? '${d.name} · ${T.cloudThisDevice.s}' : d.name,
                          d.seen == null ? null : friendlyDate(d.seen!.toLocal()),
                        ),
                      ),
                    ]),
                  ),
              ]);
            },
          ),
        ),
      ],
      const Gap(10),
      Text(T.cloudStorageNote.s, style: Txt.tiny),
    ]);
  }
}
