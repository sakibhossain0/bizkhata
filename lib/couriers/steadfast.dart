import 'dart:convert';

import 'courier.dart';

/// Steadfast Courier (Packzy API). Auth: `Api-Key` + `Secret-Key` headers.
///   GET  /ping                    reachability, no keys needed
///   POST /create_order            book a parcel
///   GET  /status_by_cid/{id}      delivery status
///   GET  /get_balance             merchant balance (used to test keys)
///   GET  /fraud_check/score/{ph}  customer delivery record
///
/// Checked against the merchant API guide (Oct 2026): invoice may hold only
/// letters, digits, `-` and `_` and must be unique; text fields are cut at
/// 100/490/480/255 characters; the reply carries its own `tracking_link`.
///
/// The fraud endpoint changed in Sept 2026: the old `/fraud_check/{phone}`
/// still answers 200 but with all-zero counts. Its quota is tiny (roughly 4×
/// your busiest day's parcels + 10), so only call it on a button press and
/// cache the answer.
class SteadfastCourier extends CourierAdapter {
  final String apiKey;
  final String secretKey;
  final String baseUrl;

  SteadfastCourier({required this.apiKey, required this.secretKey, String? baseUrl})
      : baseUrl = (baseUrl == null || baseUrl.trim().isEmpty) ? 'https://portal.packzy.com/api/v1' : baseUrl.trim();

  @override
  String get id => 'steadfast';

  Map<String, String> get _headers => {'Api-Key': apiKey, 'Secret-Key': secretKey};

  Uri _u(String path) => Uri.parse('${baseUrl.replaceAll(RegExp(r'/+$'), '')}$path');

  void _requireKeys() {
    if (apiKey.trim().isEmpty || secretKey.trim().isEmpty) {
      throw CourierException('Steadfast API key and secret key are not set (Settings → Couriers).');
    }
  }

  static String _cut(String s, int max) => s.length <= max ? s : s.substring(0, max);

  /// Steadfast accepts only letters, digits, hyphens and underscores in the invoice.
  static String safeInvoice(String invoice) => _cut(invoice.trim().replaceAll(RegExp(r'[^A-Za-z0-9_-]+'), '-'), 100);

  @override
  Future<BookResult> book(BookInput input) async {
    _requireKeys();
    final j = await Http.send('POST', _u('/create_order'), headers: _headers, body: {
      'invoice': safeInvoice(input.invoice),
      'recipient_name': _cut(input.name, 100),
      'recipient_phone': input.phone,
      'recipient_address': _cut(
          [input.address, input.area, input.city].where((e) => e != null && e.trim().isNotEmpty).join(', '), 490),
      'cod_amount': input.cod.round(),
      'note': _cut(input.note ?? '', 480),
      if (input.itemDescription != null) 'item_description': _cut(input.itemDescription!, 255),
      'total_lot': input.itemCount,
    });
    final c = j['consignment'];
    if (c is! Map) {
      throw CourierException('${j['message'] ?? 'Steadfast did not accept the parcel'}');
    }
    final code = c['tracking_code']?.toString();
    final link = c['tracking_link']?.toString();
    return BookResult(
      consignmentId: '${c['consignment_id'] ?? c['id']}',
      trackingCode: code,
      trackingUrl: link != null && link.startsWith('http') ? link : (code == null ? null : 'https://steadfast.com.bd/t/$code'),
      status: '${c['status'] ?? 'in_review'}',
      raw: jsonEncode(c),
    );
  }

  @override
  Future<String> status(String consignmentId) async {
    _requireKeys();
    final j = await Http.send('GET', _u('/status_by_cid/$consignmentId'), headers: _headers);
    return '${j['delivery_status'] ?? 'unknown'}';
  }

  @override
  Future<String> testConnection() async {
    _requireKeys();
    // /ping needs no keys: if it fails the problem is the network, not the keys.
    try {
      await Http.send('GET', _u('/ping'));
    } catch (e) {
      throw CourierException('Cannot reach Steadfast. Check the internet connection. ($e)');
    }
    final j = await Http.send('GET', _u('/get_balance'), headers: _headers);
    if (j['current_balance'] == null) throw CourierException('${j['message'] ?? 'Unexpected reply from Steadfast'}');
    return 'Balance: ৳${j['current_balance']}';
  }

  Future<FraudScore> fraudScore(String phone) async {
    _requireKeys();
    final j = await Http.send('GET', _u('/fraud_check/score/$phone'), headers: _headers);
    final data = j['data'] is Map ? Map<String, dynamic>.from(j['data'] as Map) : j;
    return FraudScore.fromJson(data, checkedAt: DateTime.now());
  }
}
