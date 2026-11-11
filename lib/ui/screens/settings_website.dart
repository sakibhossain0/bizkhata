import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/i18n.dart';
import '../../core/theme.dart';
import '../../core/util.dart';
import '../../state/website_state.dart';
import '../../web/browser_connector.dart';
import '../../web/website_sync.dart';
import '../widgets/common.dart';
import 'website_browser.dart';

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
  late BrowserSource? browser = c.browser;

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
        // A website read through the browser gives orders only.
        products: platform == 'browser' ? false : products,
        updatePrices: prices,
        stockFromWebsite: siteStock,
        enabled: enabled,
        puller: c.puller,
        browser: platform == 'browser' ? browser : null,
      );

  /// Open the built-in browser to sign in and choose the order lists; the
  /// choice is saved straight away.
  Future<void> _openSite() async {
    final folder = await ref.read(websiteProvider.notifier).browserFolder();
    if (folder == null || !mounted) return;
    final start = url.text.trim().isNotEmpty ? url.text.trim() : (browser?.pageUrl ?? '');
    final picked = await WebsiteBrowserScreen.open(context, startUrl: start, folder: folder);
    if (picked == null || !mounted) return;
    setState(() {
      browser = picked;
      if (url.text.trim().isEmpty) {
        final u = Uri.parse(picked.pageUrl);
        url.text = '${u.scheme}://${u.host}${u.hasPort ? ':${u.port}' : ''}';
      }
      // Each check loads the admin page: every 15 minutes is plenty, and kind
      // to mobile data. The owner can still choose otherwise.
      if (c.platform != 'browser' && minutes > 0 && minutes < 15) minutes = 15;
    });
    final ok = await guard(context, () => ref.read(websiteProvider.notifier).save(_draft), success: T.saved.s);
    if (ok && mounted) setState(() => c = ref.read(websiteProvider).config);
  }

  Future<void> _test() async {
    final cfg = _draft;
    if (!cfg.ready) {
      toast(
          context,
          cfg.isBrowser
              ? T.webNoListYet.s
              : cfg.url.trim().isEmpty
                  ? T.e_web_not_found.s
                  : T.e_web_auth.s,
          error: true);
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
    final viaBrowser = platform == 'browser';
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
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final (value, label) in [('woo', T.webWoo), ('json', T.webJson), ('browser', T.webBrowser)])
              ChoiceChip(
                key: ValueKey('web-platform-$value'),
                label: Text(label.s),
                selected: platform == value,
                showCheckmark: false,
                onSelected: (_) => setState(() => platform = value),
              ),
          ]),
          const Gap(14),
          TextIn(
            controller: url,
            label: woo
                ? T.webUrl.s
                : viaBrowser
                    ? T.webAdminUrl.s
                    : T.webApiUrl.s,
            hint: woo
                ? 'https://myshop.com'
                : viaBrowser
                    ? 'https://admin.myshop.com'
                    : 'https://api.myshop.com/api/bizkhata/…',
            keyboard: TextInputType.url,
            icon: Icons.language_rounded,
          ),
          const Gap(12),
          if (viaBrowser) ...[
            Text(T.webBrowserHelp.s, style: Txt.small),
            const Gap(10),
            Text(
              browser == null
                  ? T.webNoListYet.s
                  : T.webListsChosen.f({'x': browser!.lists.map((l) => l.label).join(', ')}),
              style: Txt.small.copyWith(color: browser == null ? C.warn : C.inGreen, fontWeight: FontWeight.w600),
            ),
            const Gap(4),
            Text(T.webReadOnly.s, style: Txt.tiny),
            const Gap(12),
            Wrap(spacing: 10, runSpacing: 10, crossAxisAlignment: WrapCrossAlignment.center, children: [
              FilledButton.icon(
                key: const ValueKey('web-open-site'),
                onPressed: _openSite,
                icon: const Icon(Icons.travel_explore_rounded, size: 18),
                label: Text(browser == null ? T.webOpenSite.s : T.webOpenAgain.s),
              ),
              if (browser != null) BusyButton(label: T.webTest.s, icon: Icons.wifi_tethering_rounded, onPressed: _test),
              TextButton.icon(
                key: const ValueKey('web-paste'),
                onPressed: () => PasteOrdersDialog.show(context),
                icon: const Icon(Icons.content_paste_rounded, size: 18),
                label: Text(T.webPasteInstead.s),
              ),
            ]),
          ] else if (woo)
            FieldRow(minFieldWidth: 220, children: [
              TextIn(controller: key, label: T.webKey.s, hint: 'ck_…'),
              TextIn(controller: secret, label: T.webSecret.s, hint: 'cs_…', obscure: true),
            ])
          else
            TextIn(controller: key, label: T.webApiKey.s, obscure: true),
          if (!viaBrowser) ...[
            const Gap(6),
            Text(woo ? T.webWooHelp.s : T.webJsonHelp.s, style: Txt.tiny),
            if (!woo) ...[
              const Gap(4),
              Text(T.webPushNote.s, style: Txt.tiny.copyWith(color: C.brand, fontWeight: FontWeight.w600)),
            ],
            const Gap(12),
            Align(
              alignment: Alignment.centerLeft,
              child: BusyButton(label: T.webTest.s, icon: Icons.wifi_tethering_rounded, onPressed: _test),
            ),
          ],
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
          if (!viaBrowser)
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: products,
              onChanged: (v) => setState(() => products = v),
              title: Text(T.webProducts.s, style: Txt.body),
            ),
          if (products && !viaBrowser) ...[
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
