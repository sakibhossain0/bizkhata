import 'dart:math';

import 'courier.dart';

/// Test mode: behaves like a courier without calling anyone, so a shop can
/// learn the order flow before entering real API keys.
/// Parcels "deliver" one minute after booking; IDs ending in 7 come back
/// returned so the return flow can be tried too.
class MockCourier extends CourierAdapter {
  @override
  final String id;
  MockCourier(this.id);

  static final _booked = <String, DateTime>{};

  @override
  Future<BookResult> book(BookInput input) async {
    await Future<void>.delayed(const Duration(milliseconds: 400));
    final cid = '${id.substring(0, 2).toUpperCase()}${100000 + Random().nextInt(899999)}';
    _booked[cid] = DateTime.now();
    return BookResult(
      consignmentId: cid,
      trackingCode: 'TEST$cid',
      trackingUrl: null,
      status: 'in_review',
      fee: input.city?.toLowerCase().contains('dhaka') ?? true ? 60 : 120,
    );
  }

  @override
  Future<String> status(String consignmentId) async {
    await Future<void>.delayed(const Duration(milliseconds: 150));
    final at = _booked[consignmentId];
    // Unknown IDs (e.g. after restarting the app) are treated as old parcels.
    final age = at == null ? const Duration(hours: 1) : DateTime.now().difference(at);
    if (age < const Duration(minutes: 1)) return 'in_review';
    return consignmentId.endsWith('7') ? 'cancelled' : 'delivered';
  }

  @override
  Future<String> testConnection() async => 'Test mode — no real courier is contacted';
}
