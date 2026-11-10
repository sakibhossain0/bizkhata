import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app.dart';
import '../../core/i18n.dart';
import '../../core/theme.dart';
import '../../data/seed.dart';
import '../../state/app_state.dart';
import '../widgets/common.dart';
import '../../sync/google_auth.dart';
import '../widgets/cloud_widgets.dart';

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

  @override
  void initState() {
    super.initState();
    if (widget.canCancel) step = 1;
  }

  @override
  void dispose() {
    name.dispose();
    phone.dispose();
    address.dispose();
    super.dispose();
  }

  Future<void> _create({bool demo = false}) async {
    if (!demo && name.text.trim().isEmpty) {
      toast(context, T.e_name_required.s, error: true);
      return;
    }
    setState(() => busy = true);
    try {
      await ref.read(appProvider.notifier).createBusiness(
            name: demo ? T.demoShop.s : name.text,
            typeId: demo ? 'grocery' : type,
            phone: demo ? '01700000000' : phone.text,
            address: demo ? (isBangla ? 'মিরপুর ১০, ঢাকা' : 'Mirpur 10, Dhaka') : address.text,
            demo: demo,
          );
    } catch (e) {
      if (mounted) {
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
            child: busy
                ? Center(
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      const Loading(),
                      const SizedBox(height: 16),
                      Text(T.settingUp.s, style: Txt.body.copyWith(color: C.ink2)),
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
    return Column(key: const ValueKey('details'), crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        if (widget.canCancel)
          IconButton(
            onPressed: () => ref.read(appProvider.notifier).cancelAddBusiness(),
            icon: const Icon(Icons.arrow_back_rounded),
          )
        else
          IconButton(onPressed: () => setState(() => step = 0), icon: const Icon(Icons.arrow_back_rounded)),
        const SizedBox(width: 4),
        Expanded(child: Text(T.aboutYourBusiness.s, style: Txt.display(28))),
      ]),
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
      const SizedBox(height: 12),
      Center(
        child: TextButton.icon(
          onPressed: () => _create(demo: true),
          icon: const Icon(Icons.auto_awesome_outlined, size: 18),
          label: Text(T.tryDemo.s),
        ),
      ),
      Center(child: Text(T.tryDemoHint.s, style: Txt.tiny)),
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
        Padding(
          padding: const EdgeInsets.fromLTRB(56, 56, 48, 48),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              const BrandMark(size: 44),
              const SizedBox(width: 12),
              Text(T.appName.s, style: Txt.display(24, color: Colors.white)),
            ]),
            const Spacer(),
            Text(T.welcome.s, style: Txt.display(40, color: Colors.white)),
            const SizedBox(height: 14),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: Text(T.welcomeSub.s,
                  style: TextStyle(fontFamily: kBody, fontSize: 16.5, height: 1.5, color: Colors.white.withValues(alpha: 0.75))),
            ),
            const SizedBox(height: 34),
            for (final (title, sub) in points)
              Padding(
                padding: const EdgeInsets.only(bottom: 16),
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
                          style: const TextStyle(fontFamily: kBody, fontSize: 15.5, fontWeight: FontWeight.w700, color: Colors.white)),
                      Text(sub, style: TextStyle(fontFamily: kBody, fontSize: 13.5, color: Colors.white.withValues(alpha: 0.6))),
                    ]),
                  ),
                ]),
              ),
            const Spacer(),
            Text('Made for Bangladeshi businesses · বাংলাদেশি ব্যবসার জন্য তৈরি',
                style: TextStyle(fontFamily: kBody, fontSize: 12, color: Colors.white.withValues(alpha: 0.4))),
          ]),
        ),
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
  const _LangCard({required this.title, required this.sub, required this.selected, required this.onTap});

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
          height: 120,
          padding: const EdgeInsets.all(18),
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
                  child: Text(title, style: const TextStyle(fontFamily: kBody, fontSize: 26, fontWeight: FontWeight.w700, color: C.ink)),
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
