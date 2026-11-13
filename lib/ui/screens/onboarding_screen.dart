import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app.dart';
import '../../core/i18n.dart';
import '../../core/theme.dart';
import '../../data/seed.dart';
import '../../state/app_state.dart';
import '../../state/cloud_state.dart';
import '../widgets/common.dart';
import '../../sync/cloud_sync.dart';
import '../../sync/google_auth.dart';
import '../../sync/sync_engine.dart';
import '../widgets/cloud_widgets.dart';
import 'settings_cloud.dart' show confirmLogout;

/// First screen when nobody is signed in: language, then "Continue with
/// Google". Signing in for the first time is also signing up.
class SignInScreen extends ConsumerStatefulWidget {
  const SignInScreen({super.key});
  @override
  ConsumerState<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends ConsumerState<SignInScreen> {
  bool busy = false;

  /// Bumped by Cancel, so a sign-in that finishes later is ignored here.
  int attempt = 0;

  Future<void> _signIn() async {
    final mine = ++attempt;
    setState(() => busy = true);
    try {
      await ref.read(appProvider.notifier).signIn();
    } catch (e) {
      if (mounted && mine == attempt) {
        setState(() => busy = false);
        toast(context, errorText(e), error: true);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final lang = ref.watch(langProvider);
    final wide = MediaQuery.sizeOf(context).width > 980;
    return Scaffold(
      body: Row(children: [
        if (wide) const Expanded(flex: 5, child: _Hero()),
        Expanded(
          flex: 6,
          child: Container(
            color: C.paper,
            child: Center(
              child: SingleChildScrollView(
                padding: EdgeInsets.symmetric(horizontal: context.isPhone ? 20 : 48, vertical: context.isPhone ? 24 : 40),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 520),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    if (!wide) ...[
                      Row(children: [
                        const BrandMark(size: 40),
                        const SizedBox(width: 10),
                        Text(T.appName.s, style: Txt.display(22)),
                      ]),
                      const SizedBox(height: 28),
                    ],
                    Text(T.chooseLanguage.s, style: Txt.label),
                    const SizedBox(height: 10),
                    Row(children: [
                      Expanded(
                          child: _LangCard(
                              title: 'বাংলা', sub: 'Bangla', selected: lang == Lang.bn, compact: true, onTap: () => ref.read(langProvider.notifier).set(Lang.bn))),
                      const SizedBox(width: 12),
                      Expanded(
                          child: _LangCard(
                              title: 'English', sub: 'ইংরেজি', selected: lang == Lang.en, compact: true, onTap: () => ref.read(langProvider.notifier).set(Lang.en))),
                    ]),
                    const SizedBox(height: 34),
                    Text(T.signInTitle.s, style: Txt.display(30)),
                    const SizedBox(height: 8),
                    Text(T.signInSub.s, style: Txt.body.copyWith(color: C.ink2)),
                    const SizedBox(height: 24),
                    if (busy) ...[
                      Row(children: [
                        const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.6)),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Text(Platform.isAndroid ? T.signingIn.s : T.signInBrowser.s, style: Txt.body),
                        ),
                      ]),
                      const SizedBox(height: 12),
                      TextButton(
                        onPressed: () => setState(() {
                          attempt++;
                          busy = false;
                        }),
                        child: Text(T.cancel.s),
                      ),
                    ] else
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          key: const ValueKey('continue-google'),
                          onPressed: _signIn,
                          style: FilledButton.styleFrom(minimumSize: const Size(0, 54)),
                          icon: const _GoogleMark(),
                          label: Text(T.continueGoogle.s, style: const TextStyle(fontSize: 16)),
                        ),
                      ),
                    const SizedBox(height: 22),
                    Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      const Icon(Icons.lock_outline_rounded, size: 18, color: C.ink3),
                      const SizedBox(width: 10),
                      Expanded(child: Text(T.signInWhy.s, style: Txt.small)),
                    ]),
                  ]),
                ),
              ),
            ),
          ),
        ),
      ]),
    );
  }
}

/// A plain white "G" badge for the Google button (no Google artwork bundled).
class _GoogleMark extends StatelessWidget {
  const _GoogleMark();
  @override
  Widget build(BuildContext context) => Container(
        width: 24,
        height: 24,
        alignment: Alignment.center,
        decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
        child: const Text('G',
            style: TextStyle(fontFamily: kBody, fontSize: 15, fontWeight: FontWeight.w800, color: C.brand, height: 1.1)),
      );
}

class OnboardingScreen extends ConsumerStatefulWidget {
  final bool canCancel;
  const OnboardingScreen({super.key, this.canCancel = false});

  @override
  ConsumerState<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends ConsumerState<OnboardingScreen> {
  int step = 0;
  final name = TextEditingController();
  final phone = TextEditingController();
  final address = TextEditingController();
  String type = 'grocery';
  bool busy = false;

  /// The shop being downloaded from Google Drive, shown instead of the form.
  String? opening;

  @override
  void initState() {
    super.initState();
    // With accounts the language was chosen on the sign-in screen.
    if (widget.canCancel || AppController.requireAccount) step = 1;
  }

  @override
  void dispose() {
    name.dispose();
    phone.dispose();
    address.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    if (name.text.trim().isEmpty) {
      toast(context, T.e_name_required.s, error: true);
      return;
    }
    setState(() => busy = true);
    try {
      await ref.read(appProvider.notifier).createBusiness(
            name: name.text,
            typeId: type,
            phone: phone.text,
            address: address.text,
          );
    } catch (e) {
      if (mounted) {
        setState(() => busy = false);
        toast(context, errorText(e), error: true);
      }
    }
  }

  Future<void> _openFromDrive(CloudBusiness b) async {
    final access = ref.read(driveAccessProvider.notifier);
    setState(() => opening = b.name);
    try {
      await ref.read(appProvider.notifier).openFromCloud(b, ref.read(cloudProvider));
    } catch (e) {
      if (e is SyncException && e.code == 'no_drive') access.recheck();
      if (mounted) {
        setState(() => opening = null);
        toast(context, errorText(e), error: true);
      }
    }
  }

  Future<void> _logout() => confirmLogout(context, ref);

  @override
  Widget build(BuildContext context) {
    final lang = ref.watch(langProvider);
    final wide = MediaQuery.sizeOf(context).width > 980;
    return Scaffold(
      body: Row(children: [
        if (wide) const Expanded(flex: 5, child: _Hero()),
        Expanded(
          flex: 6,
          child: Container(
            color: C.paper,
            child: busy || opening != null
                ? Center(
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      const Loading(),
                      const SizedBox(height: 16),
                      Text(opening == null ? T.settingUp.s : T.cloudOpening.f({'x': opening}),
                          textAlign: TextAlign.center, style: Txt.body.copyWith(color: C.ink2)),
                    ]),
                  )
                : Center(
                    child: SingleChildScrollView(
                      padding: EdgeInsets.symmetric(horizontal: context.isPhone ? 20 : 48, vertical: context.isPhone ? 24 : 40),
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 560),
                        child: AnimatedSwitcher(
                          duration: const Duration(milliseconds: 220),
                          child: step == 0 ? _language(lang) : _details(),
                        ),
                      ),
                    ),
                  ),
          ),
        ),
      ]),
    );
  }

  Widget _language(Lang lang) {
    return Column(key: const ValueKey('lang'), crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(T.chooseLanguage.s, style: Txt.display(30)),
      const SizedBox(height: 6),
      Text('Choose language · ভাষা বাছাই করুন', style: Txt.small),
      const SizedBox(height: 26),
      Row(children: [
        Expanded(child: _LangCard(title: 'বাংলা', sub: 'Bangla', selected: lang == Lang.bn, onTap: () => ref.read(langProvider.notifier).set(Lang.bn))),
        const SizedBox(width: 14),
        Expanded(child: _LangCard(title: 'English', sub: 'ইংরেজি', selected: lang == Lang.en, onTap: () => ref.read(langProvider.notifier).set(Lang.en))),
      ]),
      const SizedBox(height: 28),
      FilledButton.icon(
        onPressed: () => setState(() => step = 1),
        style: FilledButton.styleFrom(minimumSize: const Size(180, 50)),
        icon: const Icon(Icons.arrow_forward_rounded),
        label: Text(T.next.s),
      ),
    ]);
  }

  Widget _details() {
    final user = ref.watch(googleUserProvider);
    return Column(key: const ValueKey('details'), crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        if (widget.canCancel)
          IconButton(
            onPressed: () => ref.read(appProvider.notifier).cancelAddBusiness(),
            icon: const Icon(Icons.arrow_back_rounded),
          )
        else if (!AppController.requireAccount)
          IconButton(onPressed: () => setState(() => step = 0), icon: const Icon(Icons.arrow_back_rounded)),
        const SizedBox(width: 4),
        Expanded(child: Text(T.aboutYourBusiness.s, style: Txt.display(28))),
      ]),
      if (AppController.requireAccount && user != null) ...[
        const SizedBox(height: 10),
        Container(
          padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
          decoration: BoxDecoration(color: C.card, borderRadius: BorderRadius.circular(12), border: Border.all(color: C.line)),
          child: Row(children: [
            Avatar(user.name ?? user.email, size: 32),
            const SizedBox(width: 10),
            Expanded(child: Text(T.signedInAs.f({'x': user.email}), style: Txt.small, overflow: TextOverflow.ellipsis)),
            if (!widget.canCancel) TextButton(onPressed: _logout, child: Text(T.logout.s)),
          ]),
        ),
        if (!widget.canCancel) ...[
          const SizedBox(height: 8),
          Text(T.createOrOpen.s, style: Txt.small),
        ],
      ],
      const DriveAccessBanner(top: 14),
      // First run on this device: shops the account already keeps in Drive come first.
      if (!widget.canCancel && AppController.requireAccount) _DriveShops(onOpen: _openFromDrive),
      const SizedBox(height: 22),
      TextIn(controller: name, label: T.businessName.s, hint: T.businessNameHint.s, autofocus: true, icon: Icons.storefront_outlined),
      const SizedBox(height: 12),
      FieldRow(minFieldWidth: 220, children: [
        TextIn(controller: phone, label: '${T.phone.s} (${T.optional.s})', keyboard: TextInputType.phone, icon: Icons.phone_outlined),
        TextIn(controller: address, label: '${T.address.s} (${T.optional.s})', icon: Icons.place_outlined),
      ]),
      const SizedBox(height: 22),
      Text(T.whatDoYouSell.s, style: Txt.label),
      const SizedBox(height: 10),
      LayoutBuilder(builder: (context, c) {
        final cols = c.maxWidth > 500 ? 3 : 2;
        final w = (c.maxWidth - (cols - 1) * 10) / cols;
        return Wrap(spacing: 10, runSpacing: 10, children: [
          for (final t in businessTypes)
            SizedBox(
              width: w,
              child: _TypeCard(type: t, selected: type == t.id, onTap: () => setState(() => type = t.id)),
            ),
        ]);
      }),
      const SizedBox(height: 26),
      Row(children: [
        Expanded(
          child: FilledButton.icon(
            onPressed: _create,
            style: FilledButton.styleFrom(minimumSize: const Size(0, 52)),
            icon: const Icon(Icons.check_rounded),
            label: Text(T.startFresh.s, style: const TextStyle(fontSize: 15.5)),
          ),
        ),
      ]),
      if (GoogleConfig.ready) ...[
        const SizedBox(height: 18),
        const Divider(),
        const SizedBox(height: 10),
        Center(
          child: OutlinedButton.icon(
            onPressed: () => showOpenFromDrive(context, ref),
            icon: const Icon(Icons.cloud_download_outlined, size: 18),
            label: Text(T.openFromDrive.s),
          ),
        ),
        const SizedBox(height: 4),
        Center(child: Text(T.openFromDriveHint.s, style: Txt.tiny, textAlign: TextAlign.center)),
      ],
    ]);
  }
}

/// The signed-in account's shops in Google Drive that aren't on this device,
/// so a new phone or PC opens them instead of starting an empty shop. Shows
/// nothing while looking, when there are none, or when Drive can't be reached:
/// creating a shop below always works.
class _DriveShops extends ConsumerStatefulWidget {
  final ValueChanged<CloudBusiness> onOpen;
  const _DriveShops({required this.onOpen});

  @override
  ConsumerState<_DriveShops> createState() => _DriveShopsState();
}

class _DriveShopsState extends ConsumerState<_DriveShops> {
  Future<List<CloudBusiness>>? shops;

  @override
  Widget build(BuildContext context) {
    // Looked up once Drive is allowed (maybe through the banner above).
    if (!ref.watch(driveAccessProvider)) {
      shops = null;
      return const SizedBox.shrink();
    }
    shops ??= cloudShops(ref);
    final local = {for (final b in ref.watch(businessesProvider).value ?? const []) b.id};
    return FutureBuilder<List<CloudBusiness>>(
      future: shops,
      builder: (context, snap) {
        final list = [
          for (final b in snap.data ?? const <CloudBusiness>[])
            if (!local.contains(b.id)) b,
        ];
        if (list.isEmpty) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.only(top: 16),
          child: Panel(
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(children: [
                const Icon(Icons.cloud_download_outlined, size: 22, color: C.brand),
                const SizedBox(width: 10),
                Expanded(child: Text(T.drShopsTitle.s, style: Txt.strong.copyWith(fontSize: 16))),
              ]),
              const SizedBox(height: 4),
              Text(T.drShopsHint.s, style: Txt.small),
              const SizedBox(height: 12),
              CloudShopTiles(shops: list, onOpen: widget.onOpen),
            ]),
          ),
        );
      },
    );
  }
}

class _Hero extends StatelessWidget {
  const _Hero();

  @override
  Widget build(BuildContext context) {
    final points = isBangla
        ? const [
            ('ইন্টারনেট ছাড়াই চলে', 'সব তথ্য আপনার কম্পিউটারে, প্রতিদিন নিজে থেকে ব্যাকআপ।'),
            ('বাকির খাতা', 'কে কত পাবে, কে কত দেবে — এক নজরে।'),
            ('বারকোড দিয়ে দ্রুত বিক্রি', 'স্ক্যান করুন, রিসিট প্রিন্ট করুন।'),
            ('কুরিয়ার এক ক্লিকে', 'স্টেডফাস্ট, পাঠাও, রেডএক্স — বুকিং থেকে COD হিসাব পর্যন্ত।'),
          ]
        : const [
            ('Works without internet', 'Your data stays on this computer, backed up every day.'),
            ('Digital khata', 'See who owes you and whom you owe — at a glance.'),
            ('Fast barcode billing', 'Scan, sell, print the receipt.'),
            ('Couriers in one click', 'Steadfast, Pathao, RedX — from booking to COD settlement.'),
          ];
    return Container(
      color: C.brandDeep,
      child: Stack(children: [
        Positioned.fill(child: CustomPaint(painter: _RuledPainter())),
        // Short laptop screens (1280×680) get a tighter layout, and anything
        // still too tall scrolls instead of overflowing.
        LayoutBuilder(builder: (context, box) {
          final short = box.maxHeight < 760;
          return SingleChildScrollView(
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: box.maxHeight),
              child: IntrinsicHeight(
                child: Padding(
                  padding: EdgeInsets.fromLTRB(56, short ? 32 : 56, 48, short ? 24 : 48),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      BrandMark(size: short ? 36 : 44),
                      const SizedBox(width: 12),
                      Text(T.appName.s, style: Txt.display(short ? 21 : 24, color: Colors.white)),
                    ]),
                    const Spacer(),
                    SizedBox(height: short ? 16 : 24),
                    Text(T.welcome.s, style: Txt.display(short ? 32 : 40, color: Colors.white)),
                    SizedBox(height: short ? 8 : 14),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 440),
                      child: Text(T.welcomeSub.s,
                          style: TextStyle(
                              fontFamily: kBody, fontSize: short ? 15 : 16.5, height: 1.45, color: Colors.white.withValues(alpha: 0.75))),
                    ),
                    SizedBox(height: short ? 20 : 34),
                    for (final (title, sub) in points)
                      Padding(
                        padding: EdgeInsets.only(bottom: short ? 10 : 16),
                        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Container(
                            margin: const EdgeInsets.only(top: 3),
                            width: 20,
                            height: 20,
                            decoration: BoxDecoration(color: C.marigold, borderRadius: BorderRadius.circular(6)),
                            child: const Icon(Icons.check_rounded, size: 15, color: C.brandDeep),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Text(title,
                                  style: TextStyle(
                                      fontFamily: kBody, fontSize: short ? 14.5 : 15.5, fontWeight: FontWeight.w700, color: Colors.white)),
                              Text(sub,
                                  style: TextStyle(fontFamily: kBody, fontSize: short ? 12.5 : 13.5, color: Colors.white.withValues(alpha: 0.6))),
                            ]),
                          ),
                        ]),
                      ),
                    const Spacer(),
                    SizedBox(height: short ? 12 : 20),
                    Text('Made for Bangladeshi businesses · বাংলাদেশি ব্যবসার জন্য তৈরি',
                        maxLines: 2,
                        style: TextStyle(fontFamily: kBody, fontSize: 12, color: Colors.white.withValues(alpha: 0.4))),
                  ]),
                ),
              ),
            ),
          );
        }),
      ]),
    );
  }
}

/// Faint ledger rules + red margin line, like an open khata page.
class _RuledPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final rule = Paint()
      ..color = Colors.white.withValues(alpha: 0.035)
      ..strokeWidth = 1;
    for (double y = 30; y < size.height; y += 30) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), rule);
    }
    final margin = Paint()
      ..color = C.margin.withValues(alpha: 0.35)
      ..strokeWidth = 1.5;
    canvas.drawLine(const Offset(36, 0), Offset(36, size.height), margin);
    canvas.drawLine(const Offset(40, 0), Offset(40, size.height), margin);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _LangCard extends StatelessWidget {
  final String title;
  final String sub;
  final bool selected;
  final VoidCallback onTap;
  final bool compact;
  const _LangCard({required this.title, required this.sub, required this.selected, required this.onTap, this.compact = false});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? C.brandSoft : C.card,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          height: compact ? 84 : 120,
          padding: EdgeInsets.all(compact ? 14 : 18),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: selected ? C.brand : C.line, width: selected ? 2 : 1),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(title,
                      style: TextStyle(fontFamily: kBody, fontSize: compact ? 21 : 26, fontWeight: FontWeight.w700, color: C.ink)),
                ),
              ),
              const SizedBox(width: 8),
              Icon(selected ? Icons.check_circle_rounded : Icons.circle_outlined, color: selected ? C.brand : C.line),
            ]),
            const Spacer(),
            Text(sub, style: Txt.small),
          ]),
        ),
      ),
    );
  }
}

class _TypeCard extends StatelessWidget {
  final BusinessType type;
  final bool selected;
  final VoidCallback onTap;
  const _TypeCard({required this.type, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? C.brandSoft : C.card,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          height: 62,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: selected ? C.brand : C.line, width: selected ? 1.6 : 1),
          ),
          child: Row(children: [
            Text(type.icon, style: const TextStyle(fontSize: 22)),
            const SizedBox(width: 10),
            Expanded(
              child: Text(isBangla ? type.bn : type.en,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontFamily: kBody, fontSize: 13, height: 1.2, fontWeight: selected ? FontWeight.w700 : FontWeight.w500, color: C.ink)),
            ),
          ]),
        ),
      ),
    );
  }
}
