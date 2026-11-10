/// Round money/quantities to 2 decimals so floating point noise never
/// reaches the database.
double r2(num v) => (v * 100).roundToDouble() / 100;

/// Round to 3 decimals (quantities like 1.250 kg).
double r3(num v) => (v * 1000).roundToDouble() / 1000;

double parseNum(String? s, [double fallback = 0]) {
  if (s == null) return fallback;
  final cleaned = toLatinDigits(s).replaceAll(',', '').trim();
  return double.tryParse(cleaned) ?? fallback;
}

const _bnDigits = ['০', '১', '২', '৩', '৪', '৫', '৬', '৭', '৮', '৯'];

String toBanglaDigits(String s) {
  final b = StringBuffer();
  for (final c in s.codeUnits) {
    if (c >= 48 && c <= 57) {
      b.write(_bnDigits[c - 48]);
    } else {
      b.writeCharCode(c);
    }
  }
  return b.toString();
}

String toLatinDigits(String s) {
  final b = StringBuffer();
  for (final r in s.runes) {
    if (r >= 0x09E6 && r <= 0x09EF) {
      b.writeCharCode(48 + r - 0x09E6);
    } else {
      b.writeCharCode(r);
    }
  }
  return b.toString();
}

/// Normalise a Bangladeshi mobile number to 01XXXXXXXXX.
/// Returns the digits as typed when it can't be recognised.
String normalizePhone(String? input) {
  if (input == null) return '';
  var d = toLatinDigits(input).replaceAll(RegExp(r'[^0-9]'), '');
  if (d.startsWith('00880')) d = d.substring(4);
  if (d.startsWith('880')) d = d.substring(2);
  if (d.length == 10 && d.startsWith('1')) d = '0$d';
  return d;
}

bool isValidBdMobile(String? input) => RegExp(r'^01[3-9]\d{8}$').hasMatch(normalizePhone(input));

DateTime dayStart(DateTime d) => DateTime(d.year, d.month, d.day);
DateTime dayEnd(DateTime d) => DateTime(d.year, d.month, d.day, 23, 59, 59, 999);

class DateRange {
  final DateTime from;
  final DateTime to;
  const DateRange(this.from, this.to);

  factory DateRange.today() {
    final n = DateTime.now();
    return DateRange(dayStart(n), dayEnd(n));
  }

  factory DateRange.yesterday() {
    final n = DateTime.now().subtract(const Duration(days: 1));
    return DateRange(dayStart(n), dayEnd(n));
  }

  factory DateRange.lastDays(int days) {
    final n = DateTime.now();
    return DateRange(dayStart(n.subtract(Duration(days: days - 1))), dayEnd(n));
  }

  factory DateRange.thisMonth() {
    final n = DateTime.now();
    return DateRange(DateTime(n.year, n.month, 1), dayEnd(n));
  }

  factory DateRange.lastMonth() {
    final n = DateTime.now();
    final start = DateTime(n.year, n.month - 1, 1);
    final end = DateTime(n.year, n.month, 0);
    return DateRange(start, dayEnd(end));
  }

  factory DateRange.thisYear() {
    final n = DateTime.now();
    return DateRange(DateTime(n.year, 1, 1), dayEnd(n));
  }

  /// Everything since the dawn of the shop.
  factory DateRange.all() => DateRange(DateTime(2000), dayEnd(DateTime.now()));

  int get days => to.difference(from).inDays + 1;

  @override
  bool operator ==(Object other) => other is DateRange && other.from == from && other.to == to;

  @override
  int get hashCode => Object.hash(from, to);
}

/// Escapes a value for CSV output.
String csvCell(Object? v) {
  final s = v?.toString() ?? '';
  if (s.contains(',') || s.contains('"') || s.contains('\n')) {
    return '"${s.replaceAll('"', '""')}"';
  }
  return s;
}

String toCsv(List<List<Object?>> rows) => rows.map((r) => r.map(csvCell).join(',')).join('\r\n');

/// Minimal RFC-4180 CSV reader (quotes, escaped quotes, CRLF, BOM).
List<List<String>> parseCsv(String text) {
  if (text.startsWith('﻿')) text = text.substring(1);
  final rows = <List<String>>[];
  var row = <String>[];
  final cell = StringBuffer();
  var quoted = false;
  for (var i = 0; i < text.length; i++) {
    final ch = text[i];
    if (quoted) {
      if (ch == '"') {
        if (i + 1 < text.length && text[i + 1] == '"') {
          cell.write('"');
          i++;
        } else {
          quoted = false;
        }
      } else {
        cell.write(ch);
      }
      continue;
    }
    if (ch == '"') {
      quoted = true;
    } else if (ch == ',') {
      row.add(cell.toString());
      cell.clear();
    } else if (ch == '\n' || ch == '\r') {
      if (ch == '\r' && i + 1 < text.length && text[i + 1] == '\n') i++;
      row.add(cell.toString());
      cell.clear();
      if (row.any((c) => c.trim().isNotEmpty)) rows.add(row);
      row = <String>[];
    } else {
      cell.write(ch);
    }
  }
  if (cell.isNotEmpty || row.isNotEmpty) {
    row.add(cell.toString());
    if (row.any((c) => c.trim().isNotEmpty)) rows.add(row);
  }
  return rows;
}

/// "House 12, Dhanmondi" + area + city, without repeating parts that are
/// already in the address (e.g. "Agrabad, Chattogram" + "Chattogram").
String joinAddress(Iterable<String?> parts) {
  final out = <String>[];
  for (final raw in parts) {
    final p = raw?.trim() ?? '';
    if (p.isEmpty) continue;
    final soFar = out.join(', ').toLowerCase();
    if (soFar.contains(p.toLowerCase())) continue;
    out.add(p);
  }
  return out.join(', ');
}

class BizException implements Exception {
  final String message;
  BizException(this.message);
  @override
  String toString() => message;
}

/// Shown in Settings → About; keep in step with pubspec.yaml and the installer.
const appVersion = '1.2.1';
