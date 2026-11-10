import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/i18n.dart';
import '../../core/theme.dart';
import '../../core/util.dart';
import '../../state/website_state.dart';
import '../../web/website_sync.dart';
import '../widgets/common.dart';

/// Settings → Website orders.
class WebsiteSettings extends ConsumerStatefulWidget {
  const WebsiteSettings({super.key});
  @override
  ConsumerState<WebsiteSettings> createState() => _WebsiteSettingsState();
}

class _WebsiteSettingsState extends ConsumerState<WebsiteSettings> {
  late WebsiteConfig c = ref.read(websiteProvider).config;
  late final url = TextEditingController(text: c.url);
  late final key = TextEditingController(text: c.key);
  late final secret = TextEditingController(text: c.secret);
  late String platform = c.platform;
  late DateTime importFrom = c.importFrom ?? dayStart(DateTime.now());
  late int minutes = c.minutes;
  late bool products = c.products;
  late bool prices = c.updatePrices;
  late bool siteStock = c.stockFromWebsite;
  late bool enabled = c.enabled || !c.ready;

  @override
  void dispose() {
    url.dispose();
    key.dispose();
    secret.dispose();
    super.dispose();
  }

  WebsiteConfig get _draft => WebsiteConfig(
        platform: platform,
        url: url.text,
        key: key.text,
        secret: platform == 'woo' ? secret.text : '',
        importFrom: importFrom,
        minutes: minutes,
        products: products,
        updatePrices: prices,
        stockFromWebsite: siteStock,
        enabled: enabled,
        puller: c.puller,
      );

  Future<void> _test() async {
    final cfg = _draft;
    if (!cfg.ready) {
      toast(context, cfg.url.trim().isEmpty ? T.e_web_not_found.s : T.e_web_auth.s, error: true);
      return;
    }
    await guard(context, () async {
      final n = await ref.read(websiteProvider.notifier).test(cfg);
      if (mounted) toast(context, T.webTestOk.f({'n': n}));
    });
  }

  @override
  Widget build(BuildContext context) {
    final st = ref.watch(websiteProvider);
    final woo = platform == 'woo';
    final last = st.last;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(T.webTitle.s, style: Txt.display(22)),
          const Gap(4),
          Text(T.webHint.s, style: Txt.small),
        ]),
      ),
      if (st.config.enabled && !st.isPuller) ...[
        Panel(
          color: C.warnSoft,
          child: AdaptiveRow(children: [
            Expanded(child: Text(T.webPullerOther.s, style: Txt.body)),
            const Gap(10),
            TextButton(onPressed: () => guard(context, () => ref.read(websiteProvider.notifier).takeOver()), child: Text(T.webTakeOver.s)),
          ]),
        ),
        const Gap(16),
      ],
      Panel(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(T.webPlatform.s, style: Txt.label),
          const Gap(8),
          SegmentedButton<String>(
            showSelectedIcon: false,
            segments: [
              ButtonSegment(value: 'woo', label: Text(T.webWoo.s)),
              ButtonSegment(value: 'json', label: Text(T.webJson.s)),
            ],
            selected: {platform},
            onSelectionChanged: (v) => setState(() => platform = v.first),
          ),
          const Gap(14),
          TextIn(
            controller: url,
            label: woo ? T.webUrl.s : T.webApiUrl.s,
            hint: woo ? 'https://myshop.com' : 'https://api.myshop.com/bizkhata',
            keyboard: TextInputType.url,
            icon: Icons.language_rounded,
          ),
          const Gap(12),
          if (woo)
            FieldRow(minFieldWidth: 220, children: [
              TextIn(controller: key, label: T.webKey.s, hint: 'ck_…'),
              TextIn(controller: secret, label: T.webSecret.s, hint: 'cs_…', obscure: true),
            ])
          else
            TextIn(controller: key, label: T.webApiKey.s, obscure: true),
          const Gap(6),
          Text(woo ? T.webWooHelp.s : T.webJsonHelp.s, style: Txt.tiny),
          const Gap(12),
          Align(
            alignment: Alignment.centerLeft,
            child: BusyButton(label: T.webTest.s, icon: Icons.wifi_tethering_rounded, onPressed: _test),
          ),
        ]),
      ),
      const Gap(16),
      Panel(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          AdaptiveRow(children: [
            Expanded(child: Text(T.webImportFrom.s, style: Txt.strong)),
            OutlinedButton.icon(
              onPressed: () async {
                final d = await showDatePicker(
                    context: context, initialDate: importFrom, firstDate: DateTime(2015), lastDate: DateTime.now());
                if (d != null) setState(() => importFrom = d);
              },
              icon: const Icon(Icons.calendar_today_outlined, size: 17),
              label: Text(dateShort(importFrom)),
            ),
          ]),
          const Gap(12),
          AdaptiveRow(children: [
            Expanded(child: Text(T.webEvery.s, style: Txt.strong)),
            SizedBox(
              width: 200,
              child: DropdownButtonFormField<int>(
                initialValue: const [0, 1, 5, 15, 30, 60].contains(minutes) ? minutes : 5,
                isExpanded: true,
                items: [
                  for (final m in const [0, 1, 5, 15, 30, 60])
                    DropdownMenuItem(value: m, child: Text(m == 0 ? T.webManual.s : T.webEveryN.f({'n': number(m)}))),
                ],
                onChanged: (v) => setState(() => minutes = v ?? 5),
              ),
            ),
          ]),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: products,
            onChanged: (v) => setState(() => products = v),
            title: Text(T.webProducts.s, style: Txt.body),
          ),
          if (products) ...[
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: prices,
              onChanged: (v) => setState(() => prices = v),
              title: Text(T.webUpdatePrices.s, style: Txt.body),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: siteStock,
              onChanged: (v) => setState(() => siteStock = v),
              title: Text(T.webStockFromSite.s, style: Txt.body),
              subtitle: Text(T.webStockHint.s, style: Txt.tiny),
            ),
          ],
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: enabled,
            onChanged: (v) => setState(() => enabled = v),
            title: Text(T.webEnabled.s, style: Txt.strong),
          ),
          const Gap(4),
          Text(T.webHowItWorks.s, style: Txt.tiny),
        ]),
      ),
      const Gap(16),
      Wrap(spacing: 10, runSpacing: 10, alignment: WrapAlignment.end, children: [
        if (st.config.ready)
          BusyButton(
            label: T.webFetch.s,
            icon: Icons.download_rounded,
            onPressed: () => guard(context, () => ref.read(websiteProvider.notifier).syncNow()),
          ),
        BusyButton(
          label: T.save.s,
          icon: Icons.check_rounded,
          onPressed: () async {
            final ok = await guard(context, () => ref.read(websiteProvider.notifier).save(_draft), success: T.saved.s);
            if (ok) setState(() => c = ref.read(websiteProvider).config);
          },
        ),
      ]),
      if (last != null) ...[
        const Gap(12),
        Text(T.webLast.f({'t': friendlyDate(last.at), 'x': websiteReportText(last)}), style: Txt.small),
        for (final e in last.errors.take(3)) Text(e, style: Txt.tiny.copyWith(color: C.outRed)),
      ],
      if (st.error != null) ...[
        const Gap(6),
        Text(errorText(st.error!), style: Txt.small.copyWith(color: C.outRed)),
      ],
    ]);
  }
}
