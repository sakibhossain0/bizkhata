import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/format.dart';
import '../../core/i18n.dart';
import '../../core/theme.dart';
import '../../state/website_state.dart';
import '../../web/browser_connector.dart';
import '../../web/browser_page.dart';
import '../../web/connectors.dart';
import '../../web/order_finder.dart';
import '../../web/website_sync.dart';
import '../widgets/common.dart';

/// An order list spotted in what the website's admin panel loaded.
class _Candidate {
  final Captured cap;
  final FoundList list;
  final String pageUrl;
  final DateTime at;
  _Candidate(this.cap, this.list, this.pageUrl) : at = DateTime.now();
}

List<FoundList> _findInBody(String body) {
  try {
    return findOrderLists(jsonDecode(body));
  } catch (_) {
    return const [];
  }
}

String _withScheme(String url) {
  final u = url.trim();
  if (u.isEmpty) return 'about:blank';
  return u.startsWith('http://') || u.startsWith('https://') ? u : 'https://$u';
}

/// The built-in browser. The owner signs in to their website's admin panel
/// and opens the page that lists their orders; BizKhata spots the order lists
/// the page loads and the owner picks which to use. Returns the choice.
class WebsiteBrowserScreen extends ConsumerStatefulWidget {
  final String startUrl;
  final String folder;
  const WebsiteBrowserScreen({super.key, required this.startUrl, required this.folder});

  static Future<BrowserSource?> open(BuildContext context, {required String startUrl, required String folder}) =>
      Navigator.of(context).push<BrowserSource>(MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => WebsiteBrowserScreen(startUrl: startUrl, folder: folder),
      ));

  @override
  ConsumerState<WebsiteBrowserScreen> createState() => _WebsiteBrowserScreenState();
}

class _WebsiteBrowserScreenState extends ConsumerState<WebsiteBrowserScreen> {
  final _captures = StreamController<Captured>.broadcast();
  late final _address = TextEditingController(text: _withScheme(widget.startUrl));
  WebViewEnvironment? _env;
  bool _ready = false;
  bool _noEngine = false;
  InAppWebViewController? _ctl;
  ControllerPage? _page;
  double _progress = 0;
  bool _canBack = false;
  bool _canForward = false;
  final _found = <String, _Candidate>{};
  String? _selected;
  final _chosen = <OrderList>[];
  String? _chosenPage;
  bool _checking = false;

  @override
  void initState() {
    super.initState();
    _prepare();
  }

  Future<void> _prepare() async {
    if (await BrowserProfile.engineVersion() == null) {
      if (mounted) setState(() => _noEngine = true);
      return;
    }
    final env = await BrowserProfile.environment(widget.folder);
    if (!mounted) return;
    setState(() {
      _env = env;
      _ready = true;
    });
  }

  @override
  void dispose() {
    _captures.close();
    _address.dispose();
    super.dispose();
  }

  Future<void> _onCapture(Captured c) async {
    // The page can still send a reply or two while the screen closes.
    if (!mounted || _captures.isClosed) return;
    _captures.add(c);
    if (c.status < 200 || c.status >= 300) return;
    final lists = c.body.length > 200000 ? await compute(_findInBody, c.body) : _findInBody(c.body);
    if (lists.isEmpty || !mounted) return;
    final pageUrl = (await _ctl?.getUrl())?.toString() ?? _address.text;
    if (!mounted) return;
    setState(() {
      for (final l in lists) {
        _found['${listKey(c.url)}#${l.path}'] = _Candidate(c, l, pageUrl);
      }
      // Keep the few most recent; show the newest (what's on screen now).
      final keys = _found.keys.toList()..sort((a, b) => _found[b]!.at.compareTo(_found[a]!.at));
      for (final k in keys.skip(6)) {
        _found.remove(k);
      }
      _selected = keys.first;
    });
  }

  Future<void> _nav() async {
    final c = _ctl;
    if (c == null) return;
    final back = await c.canGoBack();
    final fwd = await c.canGoForward();
    if (!mounted) return;
    setState(() {
      _canBack = back;
      _canForward = fwd;
    });
  }

  void _go(String text) {
    final url = _withScheme(text);
    _address.text = url;
    _ctl?.loadUrl(urlRequest: URLRequest(url: WebUri(url)));
  }

  Future<void> _use(_Candidate cand) async {
    final mapping = await OrderListPreview.show(context, cand.list);
    if (mapping == null || !mounted || _page == null) return;
    setState(() => _checking = true);
    try {
      final list = await buildList(_page!, cand.cap, FoundList(cand.list.path, cand.list.rows, mapping, cand.list.score));
      if (!mounted) return;
      setState(() {
        _chosen.removeWhere((l) => l.url == list.url && l.arrayPath == list.arrayPath);
        _chosen.add(list);
        _chosenPage ??= cand.pageUrl;
      });
      toast(context, T.bwAdded.s);
    } catch (e) {
      if (mounted) toast(context, errorText(e), error: true);
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  Future<void> _readTable() async {
    final page = _page;
    if (page == null) return;
    final tables = await page.tables();
    final hits = <(PageTable, FoundList)>[
      for (final t in tables)
        if (judgeRows(t.asRows()) case final f?) (t, f),
    ]..sort((a, b) => b.$2.score.compareTo(a.$2.score));
    if (!mounted) return;
    if (hits.isEmpty) {
      toast(context, T.bwNoTable.s, error: true);
      return;
    }
    final (table, found) = hits.first;
    final mapping = await OrderListPreview.show(context, found);
    if (mapping == null || !mounted) return;
    final url = Uri.parse((await _ctl?.getUrl())?.toString() ?? _address.text);
    if (!mounted) return;
    setState(() {
      _chosen.removeWhere((l) => l.kind == 'table' && l.url == url.toString());
      _chosen.add(tableList(url, table, mapping));
      _chosenPage ??= url.toString();
    });
    toast(context, T.bwAdded.s);
  }

  void _done() => Navigator.of(context).pop(BrowserSource(pageUrl: _chosenPage!, lists: List.of(_chosen)));

  @override
  Widget build(BuildContext context) {
    // The phone's back button goes back a page in the website first.
    return PopScope(
      canPop: !_canBack,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _ctl?.goBack();
      },
      child: _scaffold(context),
    );
  }

  Widget _scaffold(BuildContext context) {
    return Scaffold(
      backgroundColor: C.paper,
      appBar: AppBar(
        backgroundColor: C.card,
        title: Text(T.bwTitle.s, style: Txt.display(18)),
        leading: IconButton(tooltip: T.close.s, icon: const Icon(Icons.close_rounded), onPressed: () => Navigator.of(context).pop()),
        actions: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: FilledButton.icon(
              key: const ValueKey('browser-done'),
              onPressed: _chosen.isEmpty ? null : _done,
              icon: const Icon(Icons.check_rounded, size: 18),
              // The chosen lists show as chips at the bottom; keep this short for phones.
              label: Text(T.done.s),
            ),
          ),
        ],
      ),
      body: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _toolbar(),
        SizedBox(height: 3, child: _progress < 1 && _ready ? LinearProgressIndicator(value: _progress) : null),
        Expanded(child: _view()),
        _bottom(),
      ]),
    );
  }

  Widget _toolbar() => Container(
        color: C.card,
        padding: const EdgeInsets.fromLTRB(6, 4, 10, 6),
        child: Row(children: [
          IconButton(tooltip: T.back.s, onPressed: _canBack ? () => _ctl?.goBack() : null, icon: const Icon(Icons.arrow_back_rounded)),
          if (!context.isPhone)
            IconButton(onPressed: _canForward ? () => _ctl?.goForward() : null, icon: const Icon(Icons.arrow_forward_rounded)),
          IconButton(onPressed: () => _ctl?.reload(), icon: const Icon(Icons.refresh_rounded)),
          const Gap(4),
          Expanded(
            child: TextField(
              controller: _address,
              keyboardType: TextInputType.url,
              textInputAction: TextInputAction.go,
              style: Txt.body,
              decoration: InputDecoration(
                isDense: true,
                hintText: T.bwAddressHint.s,
                prefixIcon: const Icon(Icons.language_rounded, size: 18),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
              ),
              onSubmitted: _go,
            ),
          ),
        ]),
      );

  Widget _view() {
    if (_noEngine) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.public_off_rounded, size: 42, color: C.ink3),
            const Gap(12),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: Text(T.e_web_no_engine.s, style: Txt.body, textAlign: TextAlign.center),
            ),
            const Gap(14),
            FilledButton.icon(
              onPressed: () => launchUrl(Uri.parse('https://developer.microsoft.com/microsoft-edge/webview2/'),
                  mode: LaunchMode.externalApplication),
              icon: const Icon(Icons.open_in_new_rounded, size: 18),
              label: Text(T.bwGetEngine.s),
            ),
          ]),
        ),
      );
    }
    if (!_ready) return const Loading();
    return InAppWebView(
      webViewEnvironment: _env,
      initialUrlRequest: URLRequest(url: WebUri(_address.text)),
      initialUserScripts: captureScripts(),
      initialSettings: InAppWebViewSettings(
        javaScriptEnabled: true,
        supportZoom: true,
        mediaPlaybackRequiresUserGesture: true,
        useHybridComposition: true,
        isInspectable: kDebugMode,
      ),
      onWebViewCreated: (c) {
        _ctl = c;
        _page = ControllerPage(c, _captures);
        listenForCaptures(c, _onCapture);
      },
      onLoadStart: (c, url) {
        if (url != null) _address.text = url.toString();
      },
      onLoadStop: (c, url) {
        _page?.loaded();
        _nav();
      },
      onReceivedError: (c, req, err) {
        if (req.isForMainFrame ?? true) _page?.loaded();
      },
      onProgressChanged: (c, p) {
        if (mounted) setState(() => _progress = p / 100);
      },
      onUpdateVisitedHistory: (c, url, reload) {
        if (url != null) _address.text = url.toString();
        _nav();
      },
    );
  }

  Widget _bottom() {
    final cand = _selected == null ? null : _found[_selected];
    final n = cand?.list.rows.length ?? 0;
    return Material(
      color: C.card,
      elevation: 6,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Wrap(spacing: 10, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
              Icon(cand == null ? Icons.login_rounded : Icons.receipt_long_rounded, size: 20, color: cand == null ? C.ink2 : C.brand),
              if (cand == null)
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 520),
                  child: Text(T.bwStart.s, style: Txt.strong),
                )
              else ...[
                Text(T.bwFound.f({'n': number(n)}), key: const ValueKey('browser-found'), style: Txt.strong.copyWith(color: C.brand)),
                if (_found.length > 1)
                  DropdownButton<String>(
                    value: _selected,
                    isDense: true,
                    underline: const SizedBox.shrink(),
                    items: [
                      for (final e in _found.entries)
                        DropdownMenuItem(
                          value: e.key,
                          child: Text('${e.value.cap.url.host}${e.value.cap.url.path} · ${number(e.value.list.rows.length)}',
                              style: Txt.small, overflow: TextOverflow.ellipsis),
                        ),
                    ],
                    onChanged: (v) => setState(() => _selected = v),
                  )
                else
                  Text('${cand.cap.url.host}${cand.cap.url.path}', style: Txt.tiny, overflow: TextOverflow.ellipsis),
              ],
            ]),
            const Gap(8),
            Wrap(spacing: 10, runSpacing: 8, alignment: WrapAlignment.end, children: [
              TextButton.icon(
                key: const ValueKey('browser-read-table'),
                onPressed: _page == null ? null : _readTable,
                icon: const Icon(Icons.table_rows_outlined, size: 18),
                label: Text(T.bwReadTable.s),
              ),
              FilledButton.icon(
                key: const ValueKey('browser-use'),
                onPressed: cand == null || _checking ? null : () => _use(cand),
                icon: _checking
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.fact_check_outlined, size: 18),
                label: Text(_checking ? T.bwChecking.s : T.bwCheckUse.s),
              ),
            ]),
            if (_chosen.isNotEmpty) ...[
              const Gap(8),
              Wrap(spacing: 8, runSpacing: 6, children: [
                for (final l in _chosen)
                  InputChip(
                    avatar: const Icon(Icons.check_circle_rounded, size: 18, color: C.inGreen),
                    label: Text(l.kind == 'table' ? '${l.label} (${T.bwReadTable.s})' : l.label, style: Txt.small),
                    onDeleted: () => setState(() {
                      _chosen.remove(l);
                      if (_chosen.isEmpty) _chosenPage = null;
                    }),
                  ),
              ]),
            ] else if (cand == null) ...[
              const Gap(6),
              Text(T.bwPrivacy.s, style: Txt.tiny),
            ],
          ]),
        ),
      ),
    );
  }
}

// ------------------------------------------------------------------ preview

/// Shows the first orders of a list as BizKhata understood them, and lets the
/// owner fix any column. Returns the (possibly corrected) mapping.
class OrderListPreview extends StatefulWidget {
  final FoundList list;
  const OrderListPreview({super.key, required this.list});

  static Future<OrderMapping?> show(BuildContext context, FoundList list) =>
      showDialog<OrderMapping>(context: context, builder: (_) => OrderListPreview(list: list));

  @override
  State<OrderListPreview> createState() => _OrderListPreviewState();
}

class _OrderListPreviewState extends State<OrderListPreview> {
  late OrderMapping mapping = widget.list.mapping;
  late final choices = widget.list.choices();

  static final _columns = <(OrderField, T)>[
    (OrderField.number, T.pvNumber),
    (OrderField.created, T.date),
    (OrderField.name, T.customer),
    (OrderField.phone, T.phone),
    (OrderField.address, T.address),
    (OrderField.total, T.total),
    (OrderField.shipping, T.pvDelivery),
    (OrderField.status, T.status),
  ];

  bool get _valid =>
      (mapping.has(OrderField.id) || mapping.has(OrderField.number)) && (mapping.has(OrderField.total) || mapping.items != null);

  String _cell(OrderField f, RemoteOrder o) => switch (f) {
        OrderField.number => o.number,
        OrderField.created => mapping.has(OrderField.created) ? dateShort(o.created.toLocal()) : '',
        OrderField.name => o.name,
        OrderField.phone => o.phone,
        OrderField.address => o.address,
        OrderField.total => money(o.total),
        OrderField.shipping => mapping.has(OrderField.shipping) ? money(o.shipping) : '',
        OrderField.status => mapping.has(OrderField.status) ? o.status : '',
        _ => '',
      };

  Future<void> _pick(OrderField f, BuildContext anchor) async {
    final box = anchor.findRenderObject() as RenderBox?;
    final pos = box == null ? Offset.zero : box.localToGlobal(Offset(0, box.size.height));
    final picked = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(pos.dx, pos.dy, pos.dx + 1, pos.dy + 1),
      constraints: const BoxConstraints(maxHeight: 420, maxWidth: 420),
      items: [
        PopupMenuItem(value: '', child: Text(T.pvNone.s, style: Txt.small.copyWith(fontStyle: FontStyle.italic))),
        for (final (path, example) in choices)
          PopupMenuItem(
            value: path,
            child: Text.rich(TextSpan(children: [
              TextSpan(text: path, style: Txt.strong.copyWith(fontSize: 13)),
              TextSpan(text: '   $example', style: Txt.tiny),
            ])),
          ),
      ],
    );
    if (picked == null) return;
    setState(() {
      mapping = mapping.withField(f, picked);
      if (f == OrderField.number && !mapping.has(OrderField.id) && picked.isNotEmpty) {
        mapping = mapping.withField(OrderField.id, picked);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final orders = [
      for (final r in widget.list.rows.take(8))
        ?mapping.toOrder(r),
    ];
    return AppDialog(
      title: T.pvTitle.s,
      icon: Icons.fact_check_outlined,
      width: 980,
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(T.cancel.s)),
        FilledButton(
          key: const ValueKey('preview-use'),
          onPressed: _valid ? () => Navigator.pop(context, mapping) : null,
          child: Text(T.pvUse.s),
        ),
      ],
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(T.pvHint.s, style: Txt.small),
        const Gap(6),
        Text(T.pvCount.f({'n': number(widget.list.rows.length)}), style: Txt.strong),
        if (!_valid) ...[
          const Gap(6),
          Text(T.pvNeed.s, style: Txt.small.copyWith(color: C.outRed)),
        ],
        const Gap(10),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: DataTable(
            headingRowHeight: 56,
            dataRowMinHeight: 36,
            dataRowMaxHeight: 52,
            columnSpacing: 22,
            columns: [
              for (final (f, label) in _columns)
                DataColumn(
                  label: Builder(
                    builder: (anchor) => InkWell(
                      onTap: () => _pick(f, anchor),
                      child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Row(mainAxisSize: MainAxisSize.min, children: [
                          Text(label.s, style: Txt.label.copyWith(color: C.ink)),
                          const Icon(Icons.arrow_drop_down_rounded, size: 18, color: C.ink2),
                        ]),
                        Text(mapping.fields[f] ?? T.pvNone.s, style: Txt.tiny.copyWith(fontSize: 10.5)),
                      ]),
                    ),
                  ),
                ),
              DataColumn(label: Text(T.items.s, style: Txt.label.copyWith(color: C.ink))),
            ],
            rows: [
              for (final o in orders)
                DataRow(cells: [
                  for (final (f, _) in _columns)
                    DataCell(ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 220),
                      child: Text(_cell(f, o), style: Txt.small.copyWith(color: C.ink), maxLines: 2, overflow: TextOverflow.ellipsis),
                    )),
                  DataCell(ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 240),
                    child: Text(
                      o.lines.isEmpty ? '-' : o.lines.map((l) => '${qty(l.qty)} × ${l.name}').join(', '),
                      style: Txt.small,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  )),
                ]),
            ],
          ),
        ),
      ]),
    );
  }
}

// -------------------------------------------------------------------- paste

/// Bring in orders by pasting a table copied from any website (or Excel).
class PasteOrdersDialog extends ConsumerStatefulWidget {
  const PasteOrdersDialog({super.key});

  static Future<void> show(BuildContext context) => showDialog<void>(context: context, builder: (_) => const PasteOrdersDialog());

  @override
  ConsumerState<PasteOrdersDialog> createState() => _PasteOrdersDialogState();
}

class _PasteOrdersDialogState extends ConsumerState<PasteOrdersDialog> {
  final _text = TextEditingController();
  FoundList? _found;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _parse(String text) {
    final (headers, rows) = parsePastedTable(text);
    setState(() => _found = headers.isEmpty ? null : judgeRows(tableRows(headers, rows)));
  }

  @override
  Widget build(BuildContext context) {
    final found = _found;
    final n = found?.orders().length ?? 0;
    return AppDialog(
      title: T.psTitle.s,
      icon: Icons.content_paste_rounded,
      width: 620,
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(T.cancel.s)),
        BusyButton(
          label: T.psBring.f({'n': number(n)}),
          icon: Icons.download_rounded,
          onPressed: found == null || n == 0
              ? null
              : () async {
                  final ok = await guard(context, () async {
                    final rep = await ref.read(websiteProvider.notifier).importPasted(found.orders());
                    if (context.mounted) toast(context, websiteReportText(rep));
                  });
                  if (ok && context.mounted) Navigator.pop(context);
                },
        ),
      ],
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(T.psHint.s, style: Txt.small),
        const Gap(10),
        TextIn(controller: _text, label: T.psField.s, maxLines: 8, onChanged: _parse),
        const Gap(8),
        if (found != null)
          Row(children: [
            const Icon(Icons.receipt_long_rounded, size: 18, color: C.brand),
            const Gap(6),
            Expanded(child: Text(T.pvCount.f({'n': number(n)}), style: Txt.strong.copyWith(color: C.brand))),
            TextButton(
              onPressed: () async {
                final m = await OrderListPreview.show(context, found);
                if (m != null) setState(() => _found = FoundList(found.path, found.rows, m, found.score));
              },
              child: Text(T.pvTitle.s),
            ),
          ])
        else if (_text.text.trim().isNotEmpty)
          Text(T.psNotOrders.s, style: Txt.small.copyWith(color: C.outRed)),
      ]),
    );
  }
}
