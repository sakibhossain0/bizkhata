import 'dart:convert';

import 'courier.dart';

class PathaoLocation {
  final int id;
  final String name;
  const PathaoLocation(this.id, this.name);
}

/// Pathao Courier (Aladdin merchant API). OAuth password grant, then Bearer.
/// Orders need numeric city/zone (area optional); we match the order's
/// free-text area/city against Pathao's lists and fall back to the defaults
/// saved in settings.
class PathaoCourier extends CourierAdapter {
  final String clientId;
  final String clientSecret;
  final String username;
  final String password;
  final int? storeId;
  final int? defaultCityId;
  final int? defaultZoneId;
  final bool sandbox;

  PathaoCourier({
    required this.clientId,
    required this.clientSecret,
    required this.username,
    required this.password,
    this.storeId,
    this.defaultCityId,
    this.defaultZoneId,
    this.sandbox = false,
  });

  @override
  String get id => 'pathao';

  String get _base => sandbox ? 'https://courier-api-sandbox.pathao.com' : 'https://api-hermes.pathao.com';
  Uri _u(String path) => Uri.parse('$_base/aladdin/api/v1$path');

  static final Map<String, (String, DateTime)> _tokens = {};

  Future<Map<String, String>> _auth() async {
    if ([clientId, clientSecret, username, password].any((s) => s.trim().isEmpty)) {
      throw CourierException('Pathao client ID/secret, email and password are not set (Settings → Couriers).');
    }
    final cacheKey = '$_base|$clientId|$username';
    final cached = _tokens[cacheKey];
    if (cached != null && cached.$2.isAfter(DateTime.now())) return {'Authorization': 'Bearer ${cached.$1}'};
    final j = await Http.send('POST', _u('/issue-token'), body: {
      'client_id': clientId,
      'client_secret': clientSecret,
      'username': username,
      'password': password,
      'grant_type': 'password',
    });
    final token = j['access_token']?.toString();
    if (token == null) throw CourierException('${j['message'] ?? 'Pathao login failed'}');
    final ttl = (j['expires_in'] is num) ? (j['expires_in'] as num).toInt() : 3600;
    _tokens[cacheKey] = (token, DateTime.now().add(Duration(seconds: (ttl - 120).clamp(60, 1 << 30))));
    return {'Authorization': 'Bearer $token'};
  }

  Future<List<PathaoLocation>> _list(String path, String idKey, String nameKey) async {
    final j = await Http.send('GET', _u(path), headers: await _auth());
    final data = j['data'];
    final rows = data is Map ? data['data'] : data;
    if (rows is! List) return const [];
    return rows
        .whereType<Map>()
        .map((r) => PathaoLocation(int.tryParse('${r[idKey]}') ?? 0, '${r[nameKey] ?? ''}'))
        .where((l) => l.id != 0)
        .toList();
  }

  Future<List<PathaoLocation>> cities() => _list('/city-list', 'city_id', 'city_name');
  Future<List<PathaoLocation>> zones(int cityId) => _list('/cities/$cityId/zone-list', 'zone_id', 'zone_name');
  Future<List<PathaoLocation>> areas(int zoneId) => _list('/zones/$zoneId/area-list', 'area_id', 'area_name');
  Future<List<PathaoLocation>> stores() => _list('/stores', 'store_id', 'store_name');

  static PathaoLocation? match(List<PathaoLocation> list, String? hint) {
    if (hint == null || hint.trim().isEmpty) return null;
    final h = hint.trim().toLowerCase();
    for (final l in list) {
      if (l.name.toLowerCase() == h) return l;
    }
    for (final l in list) {
      final n = l.name.toLowerCase();
      if (n.contains(h) || h.contains(n)) return l;
    }
    return null;
  }

  @override
  Future<BookResult> book(BookInput input) async {
    final headers = await _auth();
    var store = storeId;
    if (store == null) {
      final s = await stores();
      if (s.isEmpty) throw CourierException('No Pathao store found. Create a pickup store in the Pathao merchant panel.');
      store = s.first.id;
    }

    int? cityId = defaultCityId;
    int? zoneId = defaultZoneId;
    int? areaId;
    final city = match(await cities(), input.city);
    if (city != null) cityId = city.id;
    if (cityId != null) {
      final zone = match(await zones(cityId), input.area);
      if (zone != null) {
        zoneId = zone.id;
        final area = match(await areas(zone.id), input.area);
        areaId = area?.id;
      }
    }
    // Pathao fills city/zone from the address when they are left out (never send null),
    // so an unmatched area is not an error. Its limits: name 3-100, address 10-220
    // characters, weight 0.5-10 kg (developer API guide, Oct 2026).
    final address = [input.address, input.area, input.city]
        .where((e) => e != null && e.trim().isNotEmpty)
        .map((e) => e!.trim())
        .fold<List<String>>([], (list, e) => list.any((x) => x.toLowerCase().contains(e.toLowerCase())) ? list : [...list, e])
        .join(', ');
    final j = await Http.send('POST', _u('/orders'), headers: headers, body: {
      'store_id': store,
      'merchant_order_id': input.invoice,
      'recipient_name': input.name.length > 100 ? input.name.substring(0, 100) : input.name,
      'recipient_phone': input.phone,
      'recipient_address': address.length > 220 ? address.substring(0, 220) : address,
      'recipient_city': ?cityId,
      'recipient_zone': ?zoneId,
      'recipient_area': ?areaId,
      'delivery_type': 48,
      'item_type': 2,
      'special_instruction': input.note ?? '',
      'item_quantity': input.itemCount,
      'item_weight': input.weightKg.clamp(0.5, 10.0),
      'amount_to_collect': input.cod.round(),
      'item_description': input.itemDescription ?? '',
    });
    final d = j['data'];
    final cid = d is Map ? d['consignment_id']?.toString() : null;
    if (cid == null) throw CourierException('${j['message'] ?? 'Pathao did not accept the parcel'}');
    final fee = d is Map && d['delivery_fee'] is num ? (d['delivery_fee'] as num).toDouble() : null;
    return BookResult(
      consignmentId: cid,
      trackingCode: cid,
      trackingUrl: 'https://merchant.pathao.com/tracking?consignment_id=$cid&phone=${input.phone}',
      status: '${(d as Map)['order_status'] ?? 'Pending'}',
      fee: fee,
      raw: jsonEncode(d),
    );
  }

  @override
  Future<String> status(String consignmentId) async {
    final j = await Http.send('GET', _u('/orders/$consignmentId/info'), headers: await _auth());
    final d = j['data'];
    if (d is! Map) return 'unknown';
    return '${d['order_status_slug'] ?? d['order_status'] ?? 'unknown'}';
  }

  @override
  Future<String> testConnection() async {
    final s = await stores();
    return s.isEmpty ? 'Connected (no pickup store yet)' : 'Connected · store: ${s.first.name}';
  }
}
