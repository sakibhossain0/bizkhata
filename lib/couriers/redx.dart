import 'dart:convert';

import 'courier.dart';

class RedxArea {
  final int id;
  final String name;
  final String district;
  const RedxArea(this.id, this.name, this.district);
}

/// RedX Open API. Header: `API-ACCESS-TOKEN: Bearer <token>`.
class RedxCourier extends CourierAdapter {
  final String token;
  final int? defaultAreaId;
  final String? defaultAreaName;
  final bool sandbox;

  RedxCourier({required this.token, this.defaultAreaId, this.defaultAreaName, this.sandbox = false});

  @override
  String get id => 'redx';

  String get _base =>
      sandbox ? 'https://sandbox.redx.com.bd/v1.0.0-beta' : 'https://openapi.redx.com.bd/v1.0.0-beta';
  Uri _u(String path) => Uri.parse('$_base$path');

  Map<String, String> get _headers {
    if (token.trim().isEmpty) throw CourierException('RedX API token is not set (Settings → Couriers).');
    return {'API-ACCESS-TOKEN': 'Bearer ${token.trim()}'};
  }

  Future<List<RedxArea>> areas({String? district}) async {
    final q = district == null || district.isEmpty ? '' : '?district_name=${Uri.encodeQueryComponent(district)}';
    final j = await Http.send('GET', _u('/areas$q'), headers: _headers);
    final rows = j['areas'];
    if (rows is! List) return const [];
    return rows
        .whereType<Map>()
        .map((r) => RedxArea(int.tryParse('${r['id']}') ?? 0, '${r['name'] ?? ''}', '${r['district_name'] ?? ''}'))
        .where((a) => a.id != 0)
        .toList();
  }

  @override
  Future<BookResult> book(BookInput input) async {
    var areaId = defaultAreaId;
    var areaName = defaultAreaName ?? '';
    if (input.area != null && input.area!.trim().isNotEmpty) {
      final list = await areas(district: input.city);
      final h = input.area!.trim().toLowerCase();
      RedxArea? hit;
      for (final a in list) {
        if (a.name.toLowerCase() == h) hit = a;
      }
      hit ??= list.where((a) => a.name.toLowerCase().contains(h) || h.contains(a.name.toLowerCase())).firstOrNull;
      if (hit != null) {
        areaId = hit.id;
        areaName = hit.name;
      }
    }
    if (areaId == null) {
      throw CourierException('RedX needs a delivery area. Write the area as a RedX area name, '
          'or set a default area in Settings → Couriers.');
    }
    final j = await Http.send('POST', _u('/parcel'), headers: _headers, body: {
      'customer_name': input.name,
      'customer_phone': input.phone,
      'delivery_area': areaName,
      'delivery_area_id': areaId,
      'customer_address': input.address,
      'merchant_invoice_id': input.invoice,
      'cash_collection_amount': '${input.cod.round()}',
      'parcel_weight': (input.weightKg * 1000).round(),
      'instruction': input.note ?? '',
      'value': input.cod.round(),
      'parcel_details_json': [
        {'name': input.itemDescription ?? 'Parcel', 'category': 'general', 'value': input.cod.round()}
      ],
    });
    final tid = j['tracking_id']?.toString();
    if (tid == null) throw CourierException('${j['message'] ?? 'RedX did not accept the parcel'}');
    return BookResult(
      consignmentId: tid,
      trackingCode: tid,
      trackingUrl: 'https://redx.com.bd/track-parcel/?trackingId=$tid',
      status: 'pickup-pending',
      raw: jsonEncode(j..remove('_status')),
    );
  }

  @override
  Future<String> status(String consignmentId) async {
    final j = await Http.send('GET', _u('/parcel/info/$consignmentId'), headers: _headers);
    final p = j['parcel'];
    if (p is Map && p['status'] != null) return '${p['status']}';
    return 'unknown';
  }

  /// RedX moves a delivered parcel on to "paid" once it pays the COD out; that
  /// is still a delivery, even if our last sync never saw "delivered".
  @override
  DeliveryOutcome outcome(String rawStatus) =>
      rawStatus.trim().toLowerCase() == 'paid' ? DeliveryOutcome.delivered : mapOutcome(rawStatus);

  @override
  Future<String> testConnection() async {
    final a = await areas(district: 'Dhaka');
    return 'Connected · ${a.length} Dhaka areas';
  }
}
