import 'dart:convert';

import 'package:http/http.dart' as http;

class CourierException implements Exception {
  final String message;
  CourierException(this.message);
  @override
  String toString() => message;
}

class BookInput {
  final String invoice;
  final String name;
  final String phone; // 01XXXXXXXXX
  final String address;
  final String? area;
  final String? city;
  final double cod;
  final String? note;
  final String? itemDescription;
  final int itemCount;
  final double weightKg;
  const BookInput({
    required this.invoice,
    required this.name,
    required this.phone,
    required this.address,
    this.area,
    this.city,
    required this.cod,
    this.note,
    this.itemDescription,
    this.itemCount = 1,
    this.weightKg = 0.5,
  });
}

class BookResult {
  final String consignmentId;
  final String? trackingCode;
  final String? trackingUrl;
  final String status;
  final double? fee;
  final String raw;
  const BookResult({
    required this.consignmentId,
    this.trackingCode,
    this.trackingUrl,
    required this.status,
    this.fee,
    this.raw = '',
  });
}

enum DeliveryOutcome { inTransit, delivered, partial, returned }

/// Steadfast's fraud score endpoint (`/fraud_check/score/{phone}`).
/// Ratios are null — not 0 — when the customer has no finished parcel;
/// null means "unknown", never "clean".
class FraudScore {
  final int? deliveryRatio;
  final int? cancellationRatio;
  final String volumeBand; // none | low | medium | high | very_high
  final int totalReports;
  final Map<String, int> categories;
  final DateTime checkedAt;
  const FraudScore({
    this.deliveryRatio,
    this.cancellationRatio,
    this.volumeBand = 'none',
    this.totalReports = 0,
    this.categories = const {},
    required this.checkedAt,
  });

  bool get unknown => deliveryRatio == null && cancellationRatio == null;

  /// 0 = good, 1 = caution, 2 = risky, -1 = unknown
  int get risk {
    if (unknown) return totalReports > 0 ? 1 : -1;
    final d = deliveryRatio ?? 0;
    if (totalReports >= 3 || d < 50) return 2;
    if (totalReports > 0 || d < 80) return 1;
    return 0;
  }

  Map<String, dynamic> toJson() => {
        'delivery_ratio': deliveryRatio,
        'cancellation_ratio': cancellationRatio,
        'volume_band': volumeBand,
        'total_reports': totalReports,
        'fraud_categories': categories,
        'checked_at': checkedAt.toIso8601String(),
      };

  factory FraudScore.fromJson(Map<String, dynamic> j, {DateTime? checkedAt}) {
    int? ratio(Object? v) => v == null ? null : (v is num ? v.toInt() : int.tryParse('$v'));
    final cats = <String, int>{};
    final rawCats = j['fraud_categories'];
    if (rawCats is Map) {
      rawCats.forEach((k, v) => cats['$k'] = v is num ? v.toInt() : int.tryParse('$v') ?? 0);
    }
    return FraudScore(
      deliveryRatio: ratio(j['delivery_ratio']),
      cancellationRatio: ratio(j['cancellation_ratio']),
      volumeBand: (j['volume_band'] ?? 'none').toString(),
      totalReports: ratio(j['total_reports']) ?? 0,
      categories: cats,
      checkedAt: checkedAt ?? DateTime.tryParse('${j['checked_at']}') ?? DateTime.now(),
    );
  }
}

abstract class CourierAdapter {
  String get id;
  Future<BookResult> book(BookInput input);
  Future<String> status(String consignmentId);

  /// Throws [CourierException] when the credentials don't work.
  Future<String> testConnection();
  DeliveryOutcome outcome(String rawStatus) => mapOutcome(rawStatus);
}

String _norm(String s) => s.trim().toLowerCase().replaceAll(RegExp(r'[\s\-]+'), '_');

/// Map any courier's raw status text to what it means for the order.
/// Approval-pending states (Steadfast) are not final yet.
DeliveryOutcome mapOutcome(String raw) {
  final s = _norm(raw);
  if (s.contains('approval_pending')) return DeliveryOutcome.inTransit;
  if (s == 'partial_delivered' || s == 'partial_delivery' || s == 'partial') return DeliveryOutcome.partial;
  if (s == 'delivered') return DeliveryOutcome.delivered;
  const returned = {'cancelled', 'canceled', 'return', 'returned', 'paid_return', 'pickup_cancelled', 'returned_to_merchant'};
  if (returned.contains(s)) return DeliveryOutcome.returned;
  return DeliveryOutcome.inTransit;
}

/// Small JSON-over-HTTP helper with friendly errors.
class Http {
  static const timeout = Duration(seconds: 25);

  static Future<Map<String, dynamic>> send(
    String method,
    Uri url, {
    Map<String, String> headers = const {},
    Object? body,
  }) async {
    final h = {'Accept': 'application/json', if (body != null) 'Content-Type': 'application/json', ...headers};
    http.Response res;
    final client = http.Client();
    try {
      final req = http.Request(method, url)..headers.addAll(h);
      if (body != null) req.body = jsonEncode(body);
      final streamed = await client.send(req).timeout(timeout);
      res = await http.Response.fromStream(streamed);
    } on Exception catch (e) {
      throw CourierException('Network error: ${e.toString().split('\n').first}');
    } finally {
      client.close();
    }
    Map<String, dynamic> json;
    try {
      final decoded = res.body.isEmpty ? <String, dynamic>{} : jsonDecode(res.body);
      json = decoded is Map ? Map<String, dynamic>.from(decoded) : {'data': decoded};
    } catch (_) {
      json = {'_raw': res.body.length > 300 ? res.body.substring(0, 300) : res.body};
    }
    json['_status'] = res.statusCode;
    if (res.statusCode == 401 || res.statusCode == 403) {
      throw CourierException(_message(json) ?? 'Invalid API credentials (${res.statusCode})');
    }
    if (res.statusCode >= 400) {
      throw CourierException(_message(json) ?? 'Courier error ${res.statusCode}');
    }
    return json;
  }

  static String? _message(Map<String, dynamic> j) {
    final errors = j['errors'];
    if (errors is Map && errors.isNotEmpty) {
      final first = errors.values.first;
      return first is List && first.isNotEmpty ? '${first.first}' : '$first';
    }
    final m = j['message'] ?? j['error'] ?? j['msg'];
    return m?.toString();
  }
}
