import 'dart:io';
import 'dart:typed_data';

import 'package:barcode_widget/barcode_widget.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:screenshot/screenshot.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/format.dart';
import '../core/util.dart';
import '../core/i18n.dart';
import '../core/theme.dart';
import '../data/biz.dart';

/// Everything printable is drawn with Flutter widgets and rasterised, because
/// the PDF engine cannot shape Bangla conjuncts. Thermal printers print
/// images anyway, and at 3x the A4 output stays crisp.
class PrintService {
  static const _px = 3.0;

  static Future<Uint8List> _capture(BuildContext context, Widget child, double width) async {
    final theme = buildTheme();
    final wrapped = MediaQuery(
      data: const MediaQueryData(),
      child: Theme(
        data: theme,
        child: Material(
          color: Colors.white,
          child: DefaultTextStyle(
            style: const TextStyle(fontFamily: kBody, color: Colors.black, fontSize: 12, height: 1.3),
            child: SizedBox(width: width, child: child),
          ),
        ),
      ),
    );
    return ScreenshotController().captureFromLongWidget(
      wrapped,
      pixelRatio: _px,
      delay: const Duration(milliseconds: 40),
      context: context,
      constraints: BoxConstraints(minWidth: width, maxWidth: width),
    );
  }

  static Future<Uint8List> _pdf(List<Uint8List> pages, {required bool roll, double rollMm = 80}) async {
    final doc = pw.Document(title: 'BizKhata', author: 'BizKhata');
    for (final bytes in pages) {
      final img = pw.MemoryImage(bytes);
      if (roll) {
        final w = rollMm * PdfPageFormat.mm;
        final h = w * (img.height! / img.width!);
        doc.addPage(pw.Page(
          pageFormat: PdfPageFormat(w, h, marginAll: 0),
          build: (_) => pw.Image(img, fit: pw.BoxFit.fill),
        ));
      } else {
        doc.addPage(pw.Page(
          pageFormat: PdfPageFormat.a4.copyWith(
              marginLeft: 0, marginRight: 0, marginTop: 0, marginBottom: 0),
          build: (_) => pw.Image(img, fit: pw.BoxFit.contain, alignment: pw.Alignment.topCenter),
        ));
      }
    }
    return doc.save();
  }

  // ------------------------------------------------------------- printer (this computer only)

  static const _printerUrl = 'printer_url';
  static const _printerName = 'printer_name';

  /// Picking a fixed printer works on desktops; phones always use the system dialog.
  static bool get canPickPrinter => Platform.isWindows || Platform.isMacOS || Platform.isLinux;

  static Future<Printer?> savedPrinter() async {
    final prefs = await SharedPreferences.getInstance();
    final url = prefs.getString(_printerUrl);
    if (url == null || url.isEmpty) return null;
    return Printer(url: url, name: prefs.getString(_printerName));
  }

  static Future<void> savePrinter(Printer? printer) async {
    final prefs = await SharedPreferences.getInstance();
    if (printer == null) {
      await prefs.remove(_printerUrl);
      await prefs.remove(_printerName);
    } else {
      await prefs.setString(_printerUrl, printer.url);
      await prefs.setString(_printerName, printer.name);
    }
  }

  static Future<List<Printer>> printers() async {
    if (!canPickPrinter) return const [];
    try {
      return await Printing.listPrinters();
    } catch (_) {
      return const [];
    }
  }

  /// Straight to the saved printer; the print dialog when none is saved or it
  /// fails. True when it printed without the dialog.
  static Future<bool> _print(Uint8List pdf, String name) async {
    final printer = canPickPrinter ? await savedPrinter() : null;
    if (printer != null) {
      try {
        if (await Printing.directPrintPdf(printer: printer, onLayout: (_) async => pdf, name: name, dynamicLayout: false)) {
          return true;
        }
      } catch (_) {
        // Printer unplugged or renamed: fall back to the dialog below.
      }
    }
    await Printing.layoutPdf(onLayout: (_) async => pdf, name: name, dynamicLayout: false);
    return false;
  }

  /// A one-page test receipt for the printer settings.
  static Future<bool> printTest(BuildContext context, Map<String, String> settings) async {
    final img = await _capture(
      context,
      Padding(
        padding: const EdgeInsets.all(10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
          _ShopHeader(settings: settings),
          const _Dashed(),
          Text('${T.testPrint.s} ✓', textAlign: TextAlign.center, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          Text(dateTime(DateTime.now()), textAlign: TextAlign.center),
          const _Dashed(),
          const Text('BizKhata', textAlign: TextAlign.center, style: TextStyle(fontSize: 10, color: Colors.black54)),
        ]),
      ),
      300,
    );
    return _print(await _pdf([img], roll: true), 'BizKhata test');
  }

  /// Writes [bytes] to a temporary file and opens the system share sheet.
  static Future<void> _share(Uint8List bytes, String fileName, String mime, {String? text}) async {
    final dir = await getTemporaryDirectory();
    final f = File(p.join(dir.path, fileName));
    await f.writeAsBytes(bytes, flush: true);
    await SharePlus.instance.share(ShareParams(files: [XFile(f.path, mimeType: mime)], text: text, subject: fileName));
  }

  static Future<void> _save(Uint8List pdf, String name) async {
    await FilePicker.saveFile(fileName: '$name.pdf', bytes: pdf, allowedExtensions: ['pdf'], type: FileType.custom);
  }

  // ------------------------------------------------------------- invoices

  static Future<Uint8List> salePdf(BuildContext context, Biz biz, int saleId, {String? paper}) async {
    final detail = (await biz.sales.detail(saleId))?.net;
    if (detail == null) throw Exception('Sale not found');
    final settings = await biz.settings.all();
    final size = paper ?? settings[K.paperSize] ?? '80';
    String? accountName;
    if (detail.sale.accountId != null) accountName = (await biz.cash.byId(detail.sale.accountId!))?.name;
    if (!context.mounted) throw Exception('cancelled');
    if (size == 'a4') {
      final pages = <Uint8List>[];
      const perPage = 16;
      final chunks = <List<SaleItem>>[];
      for (var i = 0; i < detail.items.length; i += perPage) {
        chunks.add(detail.items.sublist(i, (i + perPage).clamp(0, detail.items.length)));
      }
      if (chunks.isEmpty) chunks.add(const []);
      for (var p = 0; p < chunks.length; p++) {
        if (!context.mounted) break;
        pages.add(await _capture(
          context,
          A4Invoice(
            detail: detail,
            settings: settings,
            items: chunks[p],
            startIndex: p * perPage,
            page: p + 1,
            pages: chunks.length,
            accountName: accountName,
          ),
          794,
        ));
      }
      return _pdf(pages, roll: false);
    }
    final width = size == '58' ? 220.0 : 300.0;
    final img = await _capture(context, Receipt(detail: detail, settings: settings, accountName: accountName, width: width), width);
    return _pdf([img], roll: true, rollMm: size == '58' ? 58 : 80);
  }

  /// True when it went straight to the saved printer.
  static Future<bool> printSale(BuildContext context, Biz biz, int saleId, {String? paper}) async {
    final pdf = await salePdf(context, biz, saleId, paper: paper);
    final s = await biz.sales.byId(saleId);
    return _print(pdf, s?.invoiceNo ?? 'invoice');
  }

  /// The receipt as a picture: what customers like to get on WhatsApp.
  static Future<Uint8List> saleImage(BuildContext context, Biz biz, int saleId) async {
    final detail = (await biz.sales.detail(saleId))?.net;
    if (detail == null) throw Exception('Sale not found');
    final settings = await biz.settings.all();
    String? accountName;
    if (detail.sale.accountId != null) accountName = (await biz.cash.byId(detail.sale.accountId!))?.name;
    if (!context.mounted) throw Exception('cancelled');
    return _capture(context, Receipt(detail: detail, settings: settings, accountName: accountName, width: 300), 300);
  }

  /// Share the invoice as an image (default) or an A4 PDF through the system share sheet.
  static Future<void> shareSale(BuildContext context, Biz biz, int saleId, {bool pdf = false, String? text}) async {
    final s = await biz.sales.byId(saleId);
    if (!context.mounted) return;
    final name = (s?.invoiceNo ?? 'invoice').replaceAll(RegExp(r'[^\w-]'), '_');
    if (pdf) {
      await _share(await salePdf(context, biz, saleId, paper: 'a4'), '$name.pdf', 'application/pdf', text: text);
    } else {
      await _share(await saleImage(context, biz, saleId), '$name.png', 'image/png', text: text);
    }
  }

  static Future<void> saveSalePdf(BuildContext context, Biz biz, int saleId, {String? paper}) async {
    final pdf = await salePdf(context, biz, saleId, paper: paper ?? 'a4');
    final s = await biz.sales.byId(saleId);
    await _save(pdf, s?.invoiceNo ?? 'invoice');
  }

  // ------------------------------------------------------------- day end

  /// Prints the day-end summary on the receipt paper (A4 users get it centred on the page).
  static Future<bool> printDayEnd(BuildContext context, Biz biz, DaySummary d, {bool showProfit = true}) async {
    final settings = await biz.settings.all();
    if (!context.mounted) return false;
    final a4 = (settings[K.paperSize] ?? '80') == 'a4';
    final width = (settings[K.paperSize] ?? '80') == '58' ? 220.0 : 300.0;
    final img = await _capture(context, _DayEndSlip(d: d, settings: settings, showProfit: showProfit, width: width), width);
    final pdf = await _pdf([img], roll: !a4, rollMm: width < 250 ? 58 : 80);
    return _print(pdf, 'day-end-${fileStamp(d.day)}');
  }

  // ------------------------------------------------------------- labels

  static Future<void> printLabels(BuildContext context, Biz biz, Product p, {int copies = 24, bool sheet = true}) async {
    final settings = await biz.settings.all();
    final shop = settings[K.businessName] ?? '';
    final code = (p.barcode?.isNotEmpty ?? false) ? p.barcode! : (p.sku?.isNotEmpty ?? false) ? p.sku! : 'P${p.id}';
    if (!context.mounted) return;
    Uint8List pdf;
    if (sheet) {
      // A4 sheet, 3 x 8 labels per page.
      const perPage = 24;
      final pages = <Uint8List>[];
      for (var done = 0; done < copies; done += perPage) {
        final n = (copies - done).clamp(0, perPage);
        if (!context.mounted) return;
        pages.add(await _capture(context, _LabelSheet(shop: shop, product: p, code: code, count: n), 794));
      }
      pdf = await _pdf(pages, roll: false);
    } else {
      // Label printer: one 50 x 30 mm label per page.
      if (!context.mounted) return;
      final img = await _capture(context, _Label(shop: shop, product: p, code: code, width: 190, height: 114), 190);
      final doc = pw.Document();
      final mem = pw.MemoryImage(img);
      for (var i = 0; i < copies; i++) {
        doc.addPage(pw.Page(
          pageFormat: const PdfPageFormat(50 * PdfPageFormat.mm, 30 * PdfPageFormat.mm, marginAll: 0),
          build: (_) => pw.Image(mem, fit: pw.BoxFit.fill),
        ));
      }
      pdf = await doc.save();
    }
    await _print(pdf, 'labels-${p.name}');
  }

  // ------------------------------------------------------------- khata statement

  static Future<void> printStatement(BuildContext context, Biz biz, int contactId, {bool save = false}) async {
    final contact = await biz.contacts.byId(contactId);
    if (contact == null) return;
    final lines = (await biz.contacts.watchLedger(contactId).first).reversed.toList(); // oldest first
    final settings = await biz.settings.all();
    const perPage = 22;
    final pages = <Uint8List>[];
    final total = (lines.length / perPage).ceil().clamp(1, 1000);
    for (var p = 0; p < total; p++) {
      if (!context.mounted) return;
      final chunk = lines.skip(p * perPage).take(perPage).toList();
      pages.add(await _capture(
        context,
        _Statement(contact: contact, lines: chunk, settings: settings, page: p + 1, pages: total,
            finalBalance: lines.isEmpty ? 0 : lines.last.running),
        794,
      ));
    }
    final pdf = await _pdf(pages, roll: false);
    final name = 'statement-${contact.name}';
    if (save) {
      await _save(pdf, name);
    } else {
      await _print(pdf, name);
    }
  }
}

// =============================================================== widgets

class _ShopHeader extends StatelessWidget {
  final Map<String, String> settings;
  final bool center;
  final double scale;
  const _ShopHeader({required this.settings, this.center = true, this.scale = 1});

  @override
  Widget build(BuildContext context) {
    final logo = settings[K.logoPath];
    final hasLogo = logo != null && logo.isNotEmpty && File(logo).existsSync();
    final phone = settings[K.phone] ?? '';
    final address = settings[K.address] ?? '';
    return Column(
      crossAxisAlignment: center ? CrossAxisAlignment.center : CrossAxisAlignment.start,
      children: [
        if (hasLogo) ...[
          Image.file(File(logo), height: 44 * scale, fit: BoxFit.contain),
          SizedBox(height: 4 * scale),
        ],
        Text(settings[K.businessName] ?? '',
            textAlign: center ? TextAlign.center : TextAlign.left,
            style: TextStyle(fontFamily: kBody, fontSize: 17 * scale, fontWeight: FontWeight.w700, color: Colors.black)),
        if (address.isNotEmpty)
          Text(address, textAlign: center ? TextAlign.center : TextAlign.left, style: TextStyle(fontSize: 11 * scale)),
        if (phone.isNotEmpty)
          Text(digits(phone), textAlign: center ? TextAlign.center : TextAlign.left, style: TextStyle(fontSize: 11 * scale)),
      ],
    );
  }
}

class _Dashed extends StatelessWidget {
  const _Dashed();
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: LayoutBuilder(builder: (context, c) {
          final n = (c.maxWidth / 6).floor();
          return Row(children: [
            for (var i = 0; i < n; i++)
              Expanded(child: Container(height: 1, color: i.isEven ? Colors.black54 : Colors.transparent)),
          ]);
        }),
      );
}

/// Thermal-roll receipt (58 or 80 mm).
class Receipt extends StatelessWidget {
  final SaleDetail detail;
  final Map<String, String> settings;
  final String? accountName;
  final double width;
  const Receipt({super.key, required this.detail, required this.settings, this.accountName, required this.width});

  @override
  Widget build(BuildContext context) {
    final s = detail.sale;
    final small = width < 250;
    final fs = small ? 10.5 : 11.5;
    TextStyle st([double? size, FontWeight w = FontWeight.w400]) =>
        TextStyle(fontFamily: kBody, fontSize: size ?? fs, fontWeight: w, color: Colors.black, height: 1.25);
    Widget kv(String k, String v, {bool bold = false, double? size}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 1),
          child: Row(children: [
            Expanded(child: Text(k, style: st(size, bold ? FontWeight.w700 : FontWeight.w400))),
            Text(v, style: st(size, bold ? FontWeight.w700 : FontWeight.w500)),
          ]),
        );
    final online = s.channel == 'online';
    final customer = detail.contact?.name ?? s.shipName;
    final due = detail.due;
    return Padding(
      padding: EdgeInsets.fromLTRB(small ? 6 : 10, 10, small ? 6 : 10, 14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
        _ShopHeader(settings: settings, scale: small ? 0.9 : 1),
        const _Dashed(),
        kv('${T.invoice.s}:', s.invoiceNo),
        kv('${T.date.s}:', dateTime(s.date)),
        if (customer != null) kv('${T.customer.s}:', customer),
        if ((detail.contact?.phone ?? s.shipPhone) != null) kv('${T.phone.s}:', digits(detail.contact?.phone ?? s.shipPhone!)),
        const _Dashed(),
        for (final it in detail.items)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text(it.name, style: st(null, FontWeight.w600)),
              Row(children: [
                Expanded(child: Text('${qty(it.qty)} ${unitLabel(it.unit)} × ${money(it.price, symbol: false)}', style: st(fs - 0.5))),
                Text(money(it.total, symbol: false), style: st(null, FontWeight.w600)),
              ]),
            ]),
          ),
        const _Dashed(),
        kv(T.subtotal.s, money(s.subtotal)),
        if (s.discount > 0) kv(T.discount.s, '−${money(s.discount)}'),
        if (s.vat > 0) kv(T.vat.s, money(s.vat)),
        if (s.deliveryCharge > 0) kv(T.deliveryCharge.s, money(s.deliveryCharge)),
        const SizedBox(height: 3),
        Container(
          padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
          color: Colors.black,
          child: Row(children: [
            Expanded(child: Text(T.total.s, style: st(fs + 3, FontWeight.w700).copyWith(color: Colors.white))),
            Text(money(s.total), style: st(fs + 3, FontWeight.w700).copyWith(color: Colors.white)),
          ]),
        ),
        const SizedBox(height: 3),
        if (online) ...[
          if (s.paid > 0) kv(T.advance.s, money(s.paid)),
          kv(T.cod.s, money(due > 0 ? due : 0), bold: true, size: fs + 1),
        ] else ...[
          kv('${T.paid.s}${accountName == null ? '' : ' ($accountName)'}', money(s.paid)),
          if (due > 0) kv(T.due.s, money(due), bold: true),
        ],
        if (online && s.shipAddress != null) ...[
          const _Dashed(),
          Text(T.deliveryAddress.s, style: st(fs - 0.5, FontWeight.w700)),
          Text(joinAddress([s.shipAddress, s.shipArea, s.shipCity]),
              style: st()),
        ],
        if (s.note != null && s.note!.isNotEmpty) ...[const SizedBox(height: 4), Text('${T.note.s}: ${s.note}', style: st(fs - 0.5))],
        const _Dashed(),
        if ((settings[K.receiptFooter] ?? '').isNotEmpty)
          Text(settings[K.receiptFooter]!, textAlign: TextAlign.center, style: st(null, FontWeight.w600)),
        const SizedBox(height: 4),
        Text('BizKhata', textAlign: TextAlign.center, style: st(fs - 2).copyWith(color: Colors.black54)),
      ]),
    );
  }
}

/// One A4 page of a printed invoice.
class A4Invoice extends StatelessWidget {
  final SaleDetail detail;
  final Map<String, String> settings;
  final List<SaleItem> items;
  final int startIndex;
  final int page;
  final int pages;
  final String? accountName;
  const A4Invoice({
    super.key,
    required this.detail,
    required this.settings,
    required this.items,
    required this.startIndex,
    required this.page,
    required this.pages,
    this.accountName,
  });

  @override
  Widget build(BuildContext context) {
    final s = detail.sale;
    final last = page == pages;
    const head = TextStyle(fontFamily: kBody, fontSize: 11, fontWeight: FontWeight.w700, color: Colors.white, letterSpacing: 0.4);
    const cell = TextStyle(fontFamily: kBody, fontSize: 12.5, color: Colors.black);
    final online = s.channel == 'online';
    final customer = detail.contact?.name ?? s.shipName;
    final phone = detail.contact?.phone ?? s.shipPhone;
    final address = online
        ? joinAddress([s.shipAddress, s.shipArea, s.shipCity])
        : detail.contact?.address;
    Widget row(List<Widget> cells, {Color? bg}) => Container(
          color: bg,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          child: Row(children: [
            SizedBox(width: 30, child: cells[0]),
            Expanded(flex: 6, child: cells[1]),
            Expanded(flex: 2, child: Align(alignment: Alignment.centerRight, child: cells[2])),
            Expanded(flex: 2, child: Align(alignment: Alignment.centerRight, child: cells[3])),
            Expanded(flex: 2, child: Align(alignment: Alignment.centerRight, child: cells[4])),
          ]),
        );
    Widget total(String k, String v, {bool big = false}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(children: [
            Expanded(child: Text(k, style: TextStyle(fontSize: big ? 15 : 12.5, fontWeight: big ? FontWeight.w700 : FontWeight.w400))),
            Text(v, style: TextStyle(fontSize: big ? 16 : 12.5, fontWeight: big ? FontWeight.w700 : FontWeight.w600)),
          ]),
        );

    return SizedBox(
      width: 794,
      height: 1123,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(56, 52, 56, 40),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(child: _ShopHeader(settings: settings, center: false, scale: 1.15)),
            Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Text(T.invoice.s.toUpperCase(),
                  style: const TextStyle(fontFamily: kBody, fontSize: 26, fontWeight: FontWeight.w700, color: C.brand, letterSpacing: 1)),
              const SizedBox(height: 4),
              Text('# ${s.invoiceNo}', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
              Text(dateTime(s.date), style: const TextStyle(fontSize: 12)),
              if (pages > 1) Text('$page / $pages', style: const TextStyle(fontSize: 11, color: Colors.black54)),
            ]),
          ]),
          const SizedBox(height: 22),
          if (customer != null)
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: const Color(0xFFF5F1E8), borderRadius: BorderRadius.circular(6)),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(online ? T.deliveryAddress.s.toUpperCase() : T.customer.s.toUpperCase(),
                    style: const TextStyle(fontSize: 10.5, fontWeight: FontWeight.w700, color: Colors.black54, letterSpacing: 0.8)),
                const SizedBox(height: 3),
                Text(customer, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
                if (phone != null) Text(digits(phone), style: const TextStyle(fontSize: 12.5)),
                if (address != null && address.isNotEmpty) Text(address, style: const TextStyle(fontSize: 12.5)),
              ]),
            ),
          const SizedBox(height: 16),
          row([
            const Text('#', style: head),
            Text(T.items.s.toUpperCase(), style: head),
            Text(T.qty.s.toUpperCase(), style: head),
            Text(T.price.s.toUpperCase(), style: head),
            Text(T.total.s.toUpperCase(), style: head),
          ], bg: C.brand),
          for (var i = 0; i < items.length; i++)
            row([
              Text(digits('${startIndex + i + 1}'), style: cell),
              Text(items[i].name, style: cell.copyWith(fontWeight: FontWeight.w600)),
              Text('${qty(items[i].qty)} ${unitLabel(items[i].unit)}', style: cell),
              Text(money(items[i].price, symbol: false), style: cell),
              Text(money(items[i].total, symbol: false), style: cell.copyWith(fontWeight: FontWeight.w600)),
            ], bg: i.isOdd ? const Color(0xFFFAF7F1) : null),
          const Divider(color: Colors.black26, height: 1),
          if (last) ...[
            const SizedBox(height: 14),
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  if (s.note != null && s.note!.isNotEmpty) Text('${T.note.s}: ${s.note}', style: const TextStyle(fontSize: 12)),
                  if (accountName != null && s.paid > 0)
                    Text('${T.paymentMethod.s}: $accountName', style: const TextStyle(fontSize: 12)),
                ]),
              ),
              SizedBox(
                width: 260,
                child: Column(children: [
                  total(T.subtotal.s, money(s.subtotal)),
                  if (s.discount > 0) total(T.discount.s, '−${money(s.discount)}'),
                  if (s.vat > 0) total(T.vat.s, money(s.vat)),
                  if (s.deliveryCharge > 0) total(T.deliveryCharge.s, money(s.deliveryCharge)),
                  const Divider(color: Colors.black26),
                  total(T.total.s, money(s.total), big: true),
                  total(online ? T.advance.s : T.paid.s, money(s.paid)),
                  if (detail.due > 0) total(online ? T.cod.s : T.due.s, money(detail.due), big: true),
                ]),
              ),
            ]),
          ],
          const Spacer(),
          if (last)
            Row(children: [
              Expanded(child: Text(settings[K.receiptFooter] ?? '', style: const TextStyle(fontSize: 12, color: Colors.black54))),
              Column(children: [
                Container(width: 160, height: 1, color: Colors.black45),
                const SizedBox(height: 4),
                Text(isBangla ? 'অনুমোদিত স্বাক্ষর' : 'Authorised signature', style: const TextStyle(fontSize: 11)),
              ]),
            ]),
        ]),
      ),
    );
  }
}

class _Label extends StatelessWidget {
  final String shop;
  final Product product;
  final String code;
  final double width;
  final double height;
  const _Label({required this.shop, required this.product, required this.code, required this.width, required this.height});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: height,
      padding: const EdgeInsets.fromLTRB(6, 4, 6, 4),
      color: Colors.white,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(shop, maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 8, color: Colors.black54)),
        Text(product.name, maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 10.5, fontWeight: FontWeight.w700)),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: BarcodeWidget(
              barcode: Barcode.code128(),
              data: code,
              drawText: true,
              style: const TextStyle(fontSize: 8, letterSpacing: 1),
            ),
          ),
        ),
        Text(money(product.salePrice), textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
      ]),
    );
  }
}

class _LabelSheet extends StatelessWidget {
  final String shop;
  final Product product;
  final String code;
  final int count;
  const _LabelSheet({required this.shop, required this.product, required this.code, required this.count});

  @override
  Widget build(BuildContext context) {
    // 3 columns x 8 rows on A4 (794 x 1123 at 96 dpi).
    return SizedBox(
      width: 794,
      height: 1123,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(28, 36, 28, 36),
        child: Wrap(spacing: 8, runSpacing: 8, children: [
          for (var i = 0; i < count; i++)
            Container(
              decoration: BoxDecoration(border: Border.all(color: Colors.black12)),
              child: _Label(shop: shop, product: product, code: code, width: 240, height: 122),
            ),
        ]),
      ),
    );
  }
}

class _Statement extends StatelessWidget {
  final Contact contact;
  final List<LedgerLine> lines;
  final Map<String, String> settings;
  final int page;
  final int pages;
  final double finalBalance;
  const _Statement({
    required this.contact,
    required this.lines,
    required this.settings,
    required this.page,
    required this.pages,
    required this.finalBalance,
  });

  @override
  Widget build(BuildContext context) {
    const head = TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: Colors.white);
    const cell = TextStyle(fontSize: 12, color: Colors.black);
    Widget row(List<Widget> c, {Color? bg}) => Container(
          color: bg,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: Row(children: [
            Expanded(flex: 3, child: c[0]),
            Expanded(flex: 5, child: c[1]),
            Expanded(flex: 3, child: Align(alignment: Alignment.centerRight, child: c[2])),
            Expanded(flex: 3, child: Align(alignment: Alignment.centerRight, child: c[3])),
            Expanded(flex: 3, child: Align(alignment: Alignment.centerRight, child: c[4])),
          ]),
        );
    return SizedBox(
      width: 794,
      height: 1123,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(56, 50, 56, 40),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(child: _ShopHeader(settings: settings, center: false, scale: 1.1)),
            Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Text(T.statement.s.toUpperCase(),
                  style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: C.brand, letterSpacing: 1)),
              Text(dateShort(DateTime.now()), style: const TextStyle(fontSize: 12)),
              if (pages > 1) Text('$page / $pages', style: const TextStyle(fontSize: 11, color: Colors.black54)),
            ]),
          ]),
          const SizedBox(height: 18),
          Text(contact.name, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          if (contact.phone != null) Text(digits(contact.phone!), style: const TextStyle(fontSize: 12.5)),
          const SizedBox(height: 12),
          row([
            Text(T.date.s, style: head),
            Text(T.details.s, style: head),
            Text(T.youGave.s, style: head),
            Text(T.youGot.s, style: head),
            Text(T.balance.s, style: head),
          ], bg: C.brand),
          for (var i = 0; i < lines.length; i++)
            row([
              Text(dateShort(lines[i].entry.date), style: cell),
              Text([tKey('k', lines[i].entry.kind), if (lines[i].entry.note != null) lines[i].entry.note!].join(' · '),
                  style: cell, maxLines: 2),
              Text(lines[i].entry.amount > 0 ? money(lines[i].entry.amount, symbol: false) : '', style: cell),
              Text(lines[i].entry.amount < 0 ? money(-lines[i].entry.amount, symbol: false) : '', style: cell),
              Text(money(lines[i].running, symbol: false), style: cell.copyWith(fontWeight: FontWeight.w600)),
            ], bg: i.isOdd ? const Color(0xFFFAF7F1) : null),
          const Divider(color: Colors.black26),
          if (page == pages)
            Align(
              alignment: Alignment.centerRight,
              child: Text(
                '${finalBalance >= 0 ? T.theyOweYou.s : T.youOweThem.s}: ${money(finalBalance.abs())}',
                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
              ),
            ),
        ]),
      ),
    );
  }
}

/// Day-end summary laid out like a receipt.
class _DayEndSlip extends StatelessWidget {
  final DaySummary d;
  final Map<String, String> settings;
  final bool showProfit;
  final double width;
  const _DayEndSlip({required this.d, required this.settings, required this.showProfit, required this.width});

  @override
  Widget build(BuildContext context) {
    final small = width < 250;
    final fs = small ? 10.5 : 11.5;
    TextStyle st([double? size, FontWeight w = FontWeight.w400]) =>
        TextStyle(fontFamily: kBody, fontSize: size ?? fs, fontWeight: w, color: Colors.black, height: 1.25);
    Widget kv(String k, double v, {bool bold = false, bool always = false}) {
      if (v == 0 && !bold && !always) return const SizedBox.shrink();
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 1),
        child: Row(children: [
          Expanded(child: Text(k, style: st(null, bold ? FontWeight.w700 : FontWeight.w400))),
          Text(money(v), style: st(null, bold ? FontWeight.w700 : FontWeight.w500)),
        ]),
      );
    }

    Widget head(String t) => Padding(
          padding: const EdgeInsets.only(top: 4, bottom: 2),
          child: Text(t.toUpperCase(), style: st(fs - 1, FontWeight.w700)),
        );

    return Padding(
      padding: EdgeInsets.fromLTRB(small ? 6 : 10, 10, small ? 6 : 10, 14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
        _ShopHeader(settings: settings, scale: small ? 0.9 : 1),
        const _Dashed(),
        Text(T.dayEnd.s, textAlign: TextAlign.center, style: st(fs + 2, FontWeight.w700)),
        Text(dateLong(d.day), textAlign: TextAlign.center, style: st()),
        const _Dashed(),
        kv('${T.sales.s} (${T.invoicesN.f({'n': number(d.invoices)})})', d.sales, bold: true),
        kv(T.dueSales.s, d.dueSales),
        if (showProfit) kv(T.grossProfit.s, d.grossProfit, always: true),
        head(T.moneyIn.s),
        kv(T.cashSales.s, d.paidAtSale),
        kv(T.dueCollected.s, d.dueCollected),
        kv(T.src_cod.s, d.codIn),
        kv(T.src_manual_in.s, d.otherIn),
        kv(T.moneyIn.s, d.moneyIn, bold: true),
        head(T.moneyOut.s),
        kv(T.expenses.s, d.expenses),
        kv(T.purchasePaid.s, d.purchasePaid),
        kv(T.supplierPaid.s, d.supplierPaid),
        kv(T.refunds.s, d.refunds),
        kv(T.src_manual_out.s, d.otherOut),
        kv(T.moneyOut.s, d.moneyOut, bold: true),
        const _Dashed(),
        for (final a in d.accounts) kv(a.account, a.closing, always: true),
        Container(
          margin: const EdgeInsets.only(top: 3),
          padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
          color: Colors.black,
          child: Row(children: [
            Expanded(child: Text(T.closingBalance.s, style: st(fs + 1, FontWeight.w700).copyWith(color: Colors.white))),
            Text(money(d.closing), style: st(fs + 1, FontWeight.w700).copyWith(color: Colors.white)),
          ]),
        ),
        if (d.byStaff.any((x) => x.who.isNotEmpty)) ...[
          head(T.salesByStaff.s),
          for (final x in d.byStaff) kv('${x.who.isEmpty ? T.role_owner.s : x.who} (${number(x.count)})', x.total, always: true),
        ],
        const _Dashed(),
        Text('${T.printed.s}: ${dateTime(DateTime.now())}', textAlign: TextAlign.center, style: st(fs - 1.5).copyWith(color: Colors.black54)),
      ]),
    );
  }
}
