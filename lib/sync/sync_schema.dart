import 'package:drift/drift.dart';

/// Tables that travel between devices, parents before children: remote
/// inserts are applied in this order and deletes in the reverse order.
const syncTables = <String>[
  'settings',
  'categories',
  'expense_categories',
  'accounts',
  'users',
  'contacts',
  'products',
  'purchases',
  'purchase_items',
  'sales',
  'sale_items',
  'shipments',
  'stock_moves',
  'ledger_entries',
  'cash_txns',
  'expenses',
  'fraud_checks',
  'ext_links',
];

/// The primary-key column of a synced table.
String syncKeyColumn(String table) => switch (table) {
      'settings' => 'key',
      'fraud_checks' => 'phone',
      _ => 'id',
    };

bool syncKeyIsInt(String table) => syncKeyColumn(table) == 'id';

/// Settings that belong to one device and never sync: local folders, and the
/// invoice/purchase counters (each device numbers its own documents).
const localOnlySettings = {'backup_dir', 'last_backup_at', 'next_invoice', 'next_purchase'};

/// Plain-SQL bookkeeping for Google Drive sync. None of these tables sync.
///
/// * `sync_state`   key/value: this device's id, id block, invoice tag, cursors
/// * `sync_log`     every local change since the last push (filled by triggers)
/// * `sync_meta`    when each row last changed and on which device (last write wins)
/// * `sync_applied` how far each other device's changes have been applied here
abstract final class SyncSchema {
  /// Bump when the trigger SQL changes so existing databases get the new triggers.
  static const _triggerVersion = '1';

  static const _tables = [
    'CREATE TABLE IF NOT EXISTS sync_state (k TEXT NOT NULL PRIMARY KEY, v TEXT)',
    'CREATE TABLE IF NOT EXISTS sync_log (seq INTEGER PRIMARY KEY AUTOINCREMENT, tbl TEXT NOT NULL, '
        'pk TEXT NOT NULL, del INTEGER NOT NULL, ts INTEGER NOT NULL)',
    'CREATE INDEX IF NOT EXISTS idx_sync_log_row ON sync_log (tbl, pk)',
    'CREATE TABLE IF NOT EXISTS sync_meta (tbl TEXT NOT NULL, pk TEXT NOT NULL, ts INTEGER NOT NULL, '
        'dev TEXT NOT NULL, del INTEGER NOT NULL DEFAULT 0, PRIMARY KEY (tbl, pk))',
    'CREATE TABLE IF NOT EXISTS sync_applied (dev TEXT NOT NULL PRIMARY KEY, seq INTEGER NOT NULL)',
  ];

  /// Milliseconds since 1970, never behind the newest remote change seen
  /// (so a device with a slow clock can still win a later edit).
  static const _now = "MAX(CAST((julianday('now') - 2440587.5) * 86400000 AS INTEGER), "
      "COALESCE((SELECT CAST(v AS INTEGER) FROM sync_state WHERE k = 'hlc'), 0) + 1)";

  /// Log only while sync is on, and never while applying another device's changes.
  static const _active = "(SELECT v FROM sync_state WHERE k = 'on') = '1' "
      "AND (SELECT v FROM sync_state WHERE k = 'applying') IS NULL";

  static Future<void> install(GeneratedDatabase db) async {
    for (final sql in _tables) {
      await db.customStatement(sql);
    }
    final v = await db.customSelect("SELECT v FROM sync_state WHERE k = 'triggers'").getSingleOrNull();
    if (v?.read<String?>('v') == _triggerVersion) return;
    for (final t in syncTables) {
      for (final sql in await _triggers(db, t)) {
        await db.customStatement(sql);
      }
    }
    await db.customStatement(
        "INSERT INTO sync_state (k, v) VALUES ('triggers', ?) ON CONFLICT(k) DO UPDATE SET v = excluded.v",
        [_triggerVersion]);
  }

  static Future<List<String>> _triggers(GeneratedDatabase db, String t) async {
    final col = syncKeyColumn(t);
    String key(String row) => syncKeyIsInt(t) ? 'CAST($row.$col AS TEXT)' : '$row.$col';
    var extraNew = '';
    var extraOld = '';
    if (t == 'settings') {
      final list = localOnlySettings.map((k) => "'$k'").join(', ');
      extraNew = ' AND NEW.key NOT IN ($list)';
      extraOld = ' AND OLD.key NOT IN ($list)';
    }
    var extraUpdate = extraNew;
    if (t == 'products') {
      // Stock is synced through stock_moves; a stock-only change must not
      // touch the product row, or it would overwrite a rename made elsewhere.
      final cols = (await db.customSelect('PRAGMA table_info(products)').get())
          .map((r) => r.read<String>('name'))
          .where((c) => !const {'id', 'stock', 'updated_at', 'created_at'}.contains(c));
      extraUpdate = ' AND (${cols.map((c) => 'NEW."$c" IS NOT OLD."$c"').join(' OR ')})';
    }
    return [
      'DROP TRIGGER IF EXISTS sync_${t}_i',
      'DROP TRIGGER IF EXISTS sync_${t}_u',
      'DROP TRIGGER IF EXISTS sync_${t}_d',
      'CREATE TRIGGER sync_${t}_i AFTER INSERT ON "$t" WHEN $_active$extraNew BEGIN '
          "INSERT INTO sync_log (tbl, pk, del, ts) VALUES ('$t', ${key('NEW')}, 0, $_now); END",
      'CREATE TRIGGER sync_${t}_u AFTER UPDATE ON "$t" WHEN $_active$extraUpdate BEGIN '
          "INSERT INTO sync_log (tbl, pk, del, ts) VALUES ('$t', ${key('NEW')}, 0, $_now); END",
      'CREATE TRIGGER sync_${t}_d AFTER DELETE ON "$t" WHEN $_active$extraOld BEGIN '
          "INSERT INTO sync_log (tbl, pk, del, ts) VALUES ('$t', ${key('OLD')}, 1, $_now); END",
    ];
  }

  /// This device's id block (0 for a business that has never been opened from Google Drive).
  static Future<int> idBase(GeneratedDatabase db) async {
    final r = await db.customSelect("SELECT v FROM sync_state WHERE k = 'id_base'").getSingleOrNull();
    return int.tryParse(r?.read<String?>('v') ?? '') ?? 0;
  }
}
