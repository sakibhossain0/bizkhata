import 'package:intl/intl.dart';

import 'i18n.dart';
import 'util.dart';

final _whole = NumberFormat('#,##,##0', 'en');
final _frac = NumberFormat('#,##,##0.00', 'en');
final _qty = NumberFormat('#,##,##0.###', 'en');

String _digits(String s) => isBangla ? toBanglaDigits(s) : s;

/// ৳1,25,000 or ৳1,250.50 (lakh grouping, Bangla digits in Bangla mode).
String money(num v, {bool symbol = true, bool signed = false}) {
  final rounded = r2(v);
  final abs = rounded.abs();
  final body = abs == abs.roundToDouble() ? _whole.format(abs) : _frac.format(abs);
  final sign = rounded < 0 ? '−' : (signed && rounded > 0 ? '+' : '');
  return _digits('$sign${symbol ? '৳' : ''}$body');
}

/// Compact money for chart axes: ৳12.5k, ৳3.2L
String moneyShort(num v) {
  final a = v.abs();
  String s;
  if (a >= 10000000) {
    s = '${(a / 10000000).toStringAsFixed(1)}Cr';
  } else if (a >= 100000) {
    s = '${(a / 100000).toStringAsFixed(1)}L';
  } else if (a >= 1000) {
    s = '${(a / 1000).toStringAsFixed(1)}k';
  } else {
    s = a.toStringAsFixed(0);
  }
  s = s.replaceAll('.0', '');
  return _digits('${v < 0 ? '−' : ''}৳$s');
}

String qty(num v) => _digits(_qty.format(v));

String number(num v) => _digits(_whole.format(v));

String pct(num v) => _digits('${v.toStringAsFixed(v == v.roundToDouble() ? 0 : 1)}%');

String digits(String s) => _digits(s);

String _loc() => isBangla ? 'bn' : 'en';

String dateShort(DateTime d) => DateFormat('d MMM yyyy', _loc()).format(d);

String dateLong(DateTime d) => DateFormat('EEEE, d MMMM yyyy', _loc()).format(d);

String timeShort(DateTime d) => DateFormat('h:mm a', _loc()).format(d);

String dateTime(DateTime d) => '${dateShort(d)}, ${timeShort(d)}';

String dayMonth(DateTime d) => DateFormat('d MMM', _loc()).format(d);

/// "Today, 3:40 PM" / "Yesterday" / "12 Sep 2026"
String friendlyDate(DateTime d, {bool withTime = true}) {
  final now = DateTime.now();
  final today = dayStart(now);
  final day = dayStart(d);
  final diff = today.difference(day).inDays;
  if (diff == 0) return withTime ? '${T.today.s}, ${timeShort(d)}' : T.today.s;
  if (diff == 1) return withTime ? '${T.yesterday.s}, ${timeShort(d)}' : T.yesterday.s;
  return withTime ? dateTime(d) : dateShort(d);
}

String fileStamp(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}_${d.hour.toString().padLeft(2, '0')}${d.minute.toString().padLeft(2, '0')}';
