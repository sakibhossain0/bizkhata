import 'dart:convert';

import '../database.dart';

/// Keys for the per-business key/value settings table.
abstract final class K {
  static const businessName = 'business_name';
  static const businessType = 'business_type';
  static const phone = 'phone';
  static const address = 'address';
  static const email = 'email';
  static const logoPath = 'logo_path';
  static const invoicePrefix = 'invoice_prefix';
  static const nextInvoice = 'next_invoice';
  static const nextPurchase = 'next_purchase';
  static const receiptFooter = 'receipt_footer';
  static const paperSize = 'paper_size'; // 58 | 80 | a4
  static const autoPrint = 'auto_print';
  static const vatPercent = 'vat_percent';
  static const defaultAccount = 'default_account';
  static const allowNegativeStock = 'allow_negative_stock';
  static const pinHash = 'pin_hash';
  static const onlineEnabled = 'online_enabled';
  static const courierConfig = 'courier_config'; // JSON
  static const smsConfig = 'sms_config'; // JSON
  static const lastBackupAt = 'last_backup_at';
  static const backupDir = 'backup_dir';
  static const autoLockMinutes = 'auto_lock_minutes'; // 0 = never
  static const paymentNumbers = 'payment_numbers';
  static const templates = 'msg_templates'; // JSON {kind: text}
  static const autoSms = 'auto_sms';
}

class SettingsRepo {
  final AppDatabase db;
  SettingsRepo(this.db);

  Future<String?> get(String key) async {
    final row = await (db.select(db.settings)..where((t) => t.key.equals(key))).getSingleOrNull();
    return row?.value;
  }

  Future<String> getOr(String key, String fallback) async => (await get(key)) ?? fallback;

  Future<void> set(String key, String value) =>
      db.into(db.settings).insertOnConflictUpdate(SettingsCompanion.insert(key: key, value: value));

  Future<void> setMany(Map<String, String> values) => db.transaction(() async {
        for (final e in values.entries) {
          await set(e.key, e.value);
        }
      });

  Future<void> remove(String key) => (db.delete(db.settings)..where((t) => t.key.equals(key))).go();

  Stream<Map<String, String>> watchAll() =>
      db.select(db.settings).watch().map((rows) => {for (final r in rows) r.key: r.value});

  Future<Map<String, String>> all() async => {for (final r in await db.select(db.settings).get()) r.key: r.value};

  Future<Map<String, dynamic>> getJson(String key) async {
    final raw = await get(key);
    if (raw == null || raw.isEmpty) return {};
    try {
      return Map<String, dynamic>.from(jsonDecode(raw) as Map);
    } catch (_) {
      return {};
    }
  }

  Future<void> setJson(String key, Map<String, dynamic> value) => set(key, jsonEncode(value));

  /// Reserve the next number of a sequence (invoice, purchase) atomically.
  Future<int> nextSeq(String key, {int start = 1}) => db.transaction(() async {
        final current = int.tryParse(await getOr(key, '$start')) ?? start;
        await set(key, '${current + 1}');
        return current;
      });

  /// Letter this device puts in its document numbers when the business is
  /// shared through Google Drive ('' on the first device), so two devices
  /// never print the same invoice number.
  Future<String> deviceTag() async {
    final r = await db.customSelect("SELECT v FROM sync_state WHERE k = 'tag'").getSingleOrNull();
    return r?.read<String?>('v') ?? '';
  }

  Future<String> nextInvoiceNo() async {
    final prefix = await getOr(K.invoicePrefix, 'INV-');
    final n = await nextSeq(K.nextInvoice, start: 1001);
    return '$prefix${await deviceTag()}$n';
  }

  Future<String> nextPurchaseNo() async {
    final n = await nextSeq(K.nextPurchase, start: 1);
    return 'PUR-${await deviceTag()}${n.toString().padLeft(4, '0')}';
  }

  Future<bool> flag(String key, {bool fallback = false}) async {
    final v = await get(key);
    if (v == null) return fallback;
    return v == '1' || v == 'true';
  }

  Future<void> setFlag(String key, bool value) => set(key, value ? '1' : '0');

  Future<double> number(String key, {double fallback = 0}) async =>
      double.tryParse(await getOr(key, '$fallback')) ?? fallback;
}

/// Convenience accessors on a settings snapshot map.
extension SettingsMap on Map<String, String> {
  String str(String key, [String fallback = '']) => this[key] ?? fallback;
  bool flag(String key, {bool fallback = false}) {
    final v = this[key];
    if (v == null) return fallback;
    return v == '1' || v == 'true';
  }

  double num(String key, {double fallback = 0}) => double.tryParse(this[key] ?? '') ?? fallback;

  Map<String, dynamic> json(String key) {
    final raw = this[key];
    if (raw == null || raw.isEmpty) return {};
    try {
      return Map<String, dynamic>.from(jsonDecode(raw) as Map);
    } catch (_) {
      return {};
    }
  }
}
