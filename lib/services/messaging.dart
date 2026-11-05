import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import '../core/util.dart';
import '../data/biz.dart';

class Messaging {
  /// Opens WhatsApp (desktop app or web) with the message typed in.
  /// With an empty [phone] WhatsApp asks which chat to send it to.
  static Future<bool> whatsapp(String phone, String message) {
    final p = normalizePhone(phone);
    final intl = p.startsWith('0') ? '88$p' : p;
    return launchUrl(
      Uri.parse('https://wa.me/$intl?text=${Uri.encodeComponent(message)}'),
      mode: LaunchMode.externalApplication,
    );
  }

  static Future<bool> call(String phone) => launchUrl(Uri.parse('tel:${normalizePhone(phone)}'));

  static Future<bool> openUrl(String url) => launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);

  /// Sends through the shop's own SMS gateway. The URL template comes from
  /// settings and must contain {number} and {message}, e.g.
  /// `http://bulksmsbd.net/api/smsapi?api_key=KEY&type=text&number={number}&senderid=ID&message={message}`
  static Future<void> sms(Biz biz, String phone, String message) async {
    final cfg = await biz.settings.getJson(K.smsConfig);
    final template = (cfg['url'] as String?)?.trim() ?? '';
    if (template.isEmpty || !template.contains('{number}') || !template.contains('{message}')) {
      throw BizException('sms_not_set');
    }
    final p = normalizePhone(phone);
    final number = cfg['prefix88'] == true ? '88$p' : p;
    final url = template
        .replaceAll('{number}', Uri.encodeQueryComponent(number))
        .replaceAll('{message}', Uri.encodeQueryComponent(message));
    final res = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 20));
    if (res.statusCode >= 400) throw Exception('SMS gateway error ${res.statusCode}: ${res.body}');
  }
}

/// Save a CSV that opens correctly in Excel (UTF-8 BOM keeps Bangla intact).
Future<bool> saveCsv(String fileName, List<List<Object?>> rows) async {
  final bytes = Uint8List.fromList([0xEF, 0xBB, 0xBF, ...utf8.encode(toCsv(rows))]);
  final uri = await FilePicker.saveFile(
    fileName: fileName.endsWith('.csv') ? fileName : '$fileName.csv',
    bytes: bytes,
    type: FileType.custom,
    allowedExtensions: ['csv'],
    mimeType: 'text/csv',
  );
  return uri != null;
}
