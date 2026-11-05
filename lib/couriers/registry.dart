import 'courier.dart';
import 'mock.dart';
import 'pathao.dart';
import 'redx.dart';
import 'steadfast.dart';

const courierIds = ['steadfast', 'pathao', 'redx'];

const courierNames = {
  'steadfast': 'Steadfast',
  'pathao': 'Pathao',
  'redx': 'RedX',
  'manual': 'Other / own rider',
};

/// Wraps the `courier_config` JSON saved in settings:
/// {
///   "default": "steadfast", "testMode": true, "deliveryFee": 60, "returnFee": 60,
///   "steadfast": {"apiKey": "", "secretKey": "", "baseUrl": ""},
///   "pathao": {"clientId": "", "clientSecret": "", "username": "", "password": "",
///              "storeId": 0, "cityId": 0, "zoneId": 0, "sandbox": false},
///   "redx": {"token": "", "areaId": 0, "areaName": "", "sandbox": false}
/// }
class CourierConfig {
  final Map<String, dynamic> json;
  const CourierConfig(this.json);

  bool get testMode => json['testMode'] == true;
  String get defaultCourier => (json['default'] as String?) ?? 'steadfast';
  double get deliveryFee => (json['deliveryFee'] as num?)?.toDouble() ?? 60;
  double get returnFee => (json['returnFee'] as num?)?.toDouble() ?? 0;
  bool get autoApply => json['autoApply'] != false;

  Map<String, dynamic> section(String id) => Map<String, dynamic>.from((json[id] as Map?) ?? const {});

  String _s(Map<String, dynamic> m, String k) => (m[k] ?? '').toString();
  int? _i(Map<String, dynamic> m, String k) {
    final v = m[k];
    final n = v is num ? v.toInt() : int.tryParse('${v ?? ''}');
    return (n == null || n == 0) ? null : n;
  }

  bool isConfigured(String id) {
    if (testMode) return true;
    final m = section(id);
    return switch (id) {
      'steadfast' => _s(m, 'apiKey').isNotEmpty && _s(m, 'secretKey').isNotEmpty,
      'pathao' => _s(m, 'clientId').isNotEmpty && _s(m, 'username').isNotEmpty,
      'redx' => _s(m, 'token').isNotEmpty,
      _ => false,
    };
  }

  List<String> get configured => courierIds.where(isConfigured).toList();

  CourierAdapter adapter(String id) {
    if (testMode) return MockCourier(id);
    final m = section(id);
    return switch (id) {
      'steadfast' => SteadfastCourier(apiKey: _s(m, 'apiKey'), secretKey: _s(m, 'secretKey'), baseUrl: _s(m, 'baseUrl')),
      'pathao' => PathaoCourier(
          clientId: _s(m, 'clientId'),
          clientSecret: _s(m, 'clientSecret'),
          username: _s(m, 'username'),
          password: _s(m, 'password'),
          storeId: _i(m, 'storeId'),
          defaultCityId: _i(m, 'cityId'),
          defaultZoneId: _i(m, 'zoneId'),
          sandbox: m['sandbox'] == true,
        ),
      'redx' => RedxCourier(
          token: _s(m, 'token'),
          defaultAreaId: _i(m, 'areaId'),
          defaultAreaName: _s(m, 'areaName'),
          sandbox: m['sandbox'] == true,
        ),
      _ => throw CourierException('Unknown courier: $id'),
    };
  }

  /// Steadfast is the only courier with a customer fraud/delivery record API.
  SteadfastCourier? get fraudSource {
    if (testMode) return null;
    final m = section('steadfast');
    if (_s(m, 'apiKey').isEmpty) return null;
    return SteadfastCourier(apiKey: _s(m, 'apiKey'), secretKey: _s(m, 'secretKey'), baseUrl: _s(m, 'baseUrl'));
  }
}
