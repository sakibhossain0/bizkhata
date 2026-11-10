import 'package:drift/drift.dart';

import '../sync/sync_schema.dart';

part 'database.g.dart';

// ---------------------------------------------------------------------------
// Sign convention used everywhere money moves between us and a contact:
//   LedgerEntries.amount > 0  -> the contact owes us more   (পাবো / receivable)
//   LedgerEntries.amount < 0  -> we owe the contact more    (দেবো / payable)
// A contact's balance is simply SUM(amount).
//
// CashTxns record every taka entering or leaving one of our money accounts
// (Cash, bKash, Nagad, Bank, Courier balance ...). direction = 1 in, -1 out.
// ---------------------------------------------------------------------------

class Settings extends Table {
  TextColumn get key => text()();
  TextColumn get value => text()();
  @override
  Set<Column> get primaryKey => {key};
}

@DataClassName('ProductCategory')
class Categories extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get name => text().unique()();
}

class Products extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get name => text()();
  TextColumn get sku => text().nullable()();
  TextColumn get barcode => text().nullable()();
  IntColumn get categoryId =>
      integer().nullable().references(Categories, #id, onDelete: KeyAction.setNull)();
  TextColumn get unit => text().withDefault(const Constant('pcs'))();

  /// Weighted-average purchase cost; updated on every purchase.
  RealColumn get costPrice => real().withDefault(const Constant(0))();
  RealColumn get salePrice => real().withDefault(const Constant(0))();
  RealColumn get wholesalePrice => real().withDefault(const Constant(0))();
  RealColumn get stock => real().withDefault(const Constant(0))();
  RealColumn get lowStock => real().withDefault(const Constant(0))();
  BoolColumn get trackStock => boolean().withDefault(const Constant(true))();
  TextColumn get imagePath => text().nullable()();
  TextColumn get description => text().nullable()();
  BoolColumn get active => boolean().withDefault(const Constant(true))();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get updatedAt => dateTime().nullable()();
}

class Contacts extends Table {
  IntColumn get id => integer().autoIncrement()();

  /// 'customer' | 'supplier'
  TextColumn get type => text()();
  TextColumn get name => text()();
  TextColumn get phone => text().nullable()();
  TextColumn get address => text().nullable()();
  TextColumn get email => text().nullable()();
  TextColumn get note => text().nullable()();
  BoolColumn get active => boolean().withDefault(const Constant(true))();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
}

class LedgerEntries extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get contactId => integer().references(Contacts, #id, onDelete: KeyAction.cascade)();
  DateTimeColumn get date => dateTime()();

  /// opening | gave | got | sale | purchase | payment | return | refund
  TextColumn get kind => text()();
  RealColumn get amount => real()();
  TextColumn get refType => text().nullable()();
  IntColumn get refId => integer().nullable()();
  IntColumn get accountId => integer().nullable()();
  TextColumn get note => text().nullable()();
  TextColumn get createdBy => text().nullable()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
}

class Accounts extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get name => text()();

  /// cash | mobile | bank | card | courier | other
  TextColumn get kind => text().withDefault(const Constant('cash'))();
  RealColumn get opening => real().withDefault(const Constant(0))();
  BoolColumn get active => boolean().withDefault(const Constant(true))();
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();
}

class CashTxns extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get accountId => integer().references(Accounts, #id)();
  DateTimeColumn get date => dateTime()();

  /// 1 = money in, -1 = money out
  IntColumn get direction => integer()();
  RealColumn get amount => real()();

  /// sale | purchase | expense | khata | cod | refund | transfer | manual_in | manual_out
  TextColumn get source => text()();
  TextColumn get refType => text().nullable()();
  IntColumn get refId => integer().nullable()();
  IntColumn get contactId => integer().nullable()();
  TextColumn get note => text().nullable()();
  TextColumn get createdBy => text().nullable()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
}

class Sales extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get invoiceNo => text().unique()();
  DateTimeColumn get date => dateTime()();
  IntColumn get contactId =>
      integer().nullable().references(Contacts, #id, onDelete: KeyAction.setNull)();

  /// 'pos' (counter sale) | 'online' (delivery order)
  TextColumn get channel => text().withDefault(const Constant('pos'))();
  RealColumn get subtotal => real().withDefault(const Constant(0))();
  RealColumn get discount => real().withDefault(const Constant(0))();
  RealColumn get vat => real().withDefault(const Constant(0))();
  RealColumn get deliveryCharge => real().withDefault(const Constant(0))();
  RealColumn get total => real().withDefault(const Constant(0))();
  RealColumn get paid => real().withDefault(const Constant(0))();
  RealColumn get costTotal => real().withDefault(const Constant(0))();

  /// pos: completed | returned
  /// online: pending | confirmed | booked | delivered | partial | returned | cancelled
  TextColumn get status => text().withDefault(const Constant('completed'))();
  IntColumn get accountId => integer().nullable()();
  TextColumn get note => text().nullable()();
  TextColumn get shipName => text().nullable()();
  TextColumn get shipPhone => text().nullable()();
  TextColumn get shipAddress => text().nullable()();
  TextColumn get shipArea => text().nullable()();
  TextColumn get shipCity => text().nullable()();
  TextColumn get createdBy => text().nullable()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get updatedAt => dateTime().nullable()();
}

class SaleItems extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get saleId => integer().references(Sales, #id, onDelete: KeyAction.cascade)();
  IntColumn get productId =>
      integer().nullable().references(Products, #id, onDelete: KeyAction.setNull)();
  TextColumn get name => text()();
  RealColumn get qty => real()();
  TextColumn get unit => text().nullable()();
  RealColumn get price => real()();
  RealColumn get cost => real().withDefault(const Constant(0))();
  RealColumn get total => real()();

  /// Quantity already taken back by (partial) returns.
  RealColumn get returnedQty => real().withDefault(const Constant(0))();
}

class Purchases extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get refNo => text()();
  DateTimeColumn get date => dateTime()();
  IntColumn get contactId =>
      integer().nullable().references(Contacts, #id, onDelete: KeyAction.setNull)();
  RealColumn get subtotal => real().withDefault(const Constant(0))();
  RealColumn get discount => real().withDefault(const Constant(0))();
  RealColumn get total => real().withDefault(const Constant(0))();
  RealColumn get paid => real().withDefault(const Constant(0))();
  IntColumn get accountId => integer().nullable()();

  /// completed | cancelled
  TextColumn get status => text().withDefault(const Constant('completed'))();
  TextColumn get note => text().nullable()();
  TextColumn get createdBy => text().nullable()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
}

class PurchaseItems extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get purchaseId => integer().references(Purchases, #id, onDelete: KeyAction.cascade)();
  IntColumn get productId =>
      integer().nullable().references(Products, #id, onDelete: KeyAction.setNull)();
  TextColumn get name => text()();
  RealColumn get qty => real()();
  RealColumn get unitCost => real()();
  RealColumn get total => real()();
}

class StockMoves extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get productId => integer().references(Products, #id, onDelete: KeyAction.cascade)();
  DateTimeColumn get date => dateTime()();

  /// Signed quantity change.
  RealColumn get qty => real()();

  /// opening | sale | purchase | return | adjust | damage | lost | cancel
  TextColumn get kind => text()();
  TextColumn get refType => text().nullable()();
  IntColumn get refId => integer().nullable()();
  TextColumn get note => text().nullable()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
}

class Expenses extends Table {
  IntColumn get id => integer().autoIncrement()();
  DateTimeColumn get date => dateTime()();
  TextColumn get category => text()();
  RealColumn get amount => real()();
  IntColumn get accountId => integer().nullable()();
  TextColumn get note => text().nullable()();
  TextColumn get refType => text().nullable()();
  IntColumn get refId => integer().nullable()();
  TextColumn get createdBy => text().nullable()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
}

class ExpenseCategories extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get name => text().unique()();
}

class Shipments extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get saleId => integer().references(Sales, #id, onDelete: KeyAction.cascade)();

  /// steadfast | pathao | redx | manual
  TextColumn get courier => text()();
  TextColumn get consignmentId => text().nullable()();
  TextColumn get trackingCode => text().nullable()();
  TextColumn get trackingUrl => text().nullable()();
  TextColumn get courierStatus => text().nullable()();
  RealColumn get codAmount => real().withDefault(const Constant(0))();
  RealColumn get fee => real().withDefault(const Constant(0))();
  DateTimeColumn get bookedAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime().nullable()();
  TextColumn get rawJson => text().nullable()();
}

/// Staff who can log in with their own PIN. The owner is not a row here;
/// the owner's PIN lives in settings (`pin_hash`).
@DataClassName('StaffUser')
class Users extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get name => text()();

  /// `salt:sha256(salt+pin)`
  TextColumn get pinHash => text()();

  /// manager | cashier
  TextColumn get role => text().withDefault(const Constant('cashier'))();
  BoolColumn get active => boolean().withDefault(const Constant(true))();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
}

/// Ties a record here to the same record in an outside system (a website's
/// order or product), so repeated website syncs update instead of duplicating.
class ExtLinks extends Table {
  IntColumn get id => integer().autoIncrement()();

  /// order | product
  TextColumn get kind => text()();

  /// Which outside system, e.g. `web`.
  TextColumn get source => text()();
  TextColumn get extId => text()();
  IntColumn get localId => integer()();

  /// The outside system's own last-changed stamp, to skip unchanged records.
  TextColumn get extUpdated => text().nullable()();

  @override
  List<Set<Column>> get uniqueKeys => [
        {kind, source, extId},
      ];
}

class FraudChecks extends Table {
  TextColumn get phone => text()();
  TextColumn get json => text()();
  DateTimeColumn get checkedAt => dateTime()();
  @override
  Set<Column> get primaryKey => {phone};
}

@DriftDatabase(tables: [
  Settings,
  Categories,
  Products,
  Contacts,
  LedgerEntries,
  Accounts,
  CashTxns,
  Sales,
  SaleItems,
  Purchases,
  PurchaseItems,
  StockMoves,
  Expenses,
  ExpenseCategories,
  Shipments,
  FraudChecks,
  Users,
  ExtLinks,
])
class AppDatabase extends _$AppDatabase {
  AppDatabase(super.e);

  /// Who is using the app right now (owner or a staff name). Stamped on new
  /// sales, purchases, expenses, cash and khata entries as `created_by`.
  String? actor;

  @override
  int get schemaVersion => 3;

  // ---------------------------------------------------------------- ids
  //
  // Each device that syncs a business hands out ids from its own block,
  // [idBase, idBase + idBlock), so rows created on two devices never collide.
  // A business that has never synced uses block 0, which is exactly the old
  // behaviour (1, 2, 3 ...).

  static const idBlock = 1000000000000;

  /// Start of this device's id block (from `sync_state`; 0 until it joins a synced business).
  int idBase = 0;
  final _lastIds = <String, int>{};

  /// The next free id for [table] in this device's block.
  Future<int> nextId(TableInfo table) async {
    final name = table.actualTableName;
    var last = _lastIds[name];
    if (last == null) {
      final r = await customSelect(
        'SELECT MAX(id) AS m FROM "$name" WHERE id >= ? AND id < ?',
        variables: [Variable.withInt(idBase), Variable.withInt(idBase + idBlock)],
      ).getSingle();
      last = r.readNullable<int>('m') ?? idBase;
    }
    last++;
    _lastIds[name] = last;
    return last;
  }

  /// Insert with an id from this device's block. Every insert into a table
  /// with an integer `id` goes through here.
  Future<int> insertRow<T extends Table, D>(TableInfo<T, D> table, Insertable<D> row, {InsertMode? mode}) async {
    final cols = Map<String, Expression>.of(row.toColumns(true));
    if (!cols.containsKey('id')) cols['id'] = Variable.withInt(await nextId(table));
    return into(table).insert(RawValuesInsertable<D>(cols), mode: mode);
  }

  /// Forget cached ids, after rows were written by someone other than [insertRow].
  void resetIdCache() => _lastIds.clear();

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) async {
          await m.createAll();
          await _createIndexes();
          await SyncSchema.install(this);
        },
        onUpgrade: (m, from, to) async {
          if (from < 2) {
            // v2: staff accounts, who-did-what, partial returns.
            await m.createTable(users);
            await m.addColumn(sales, sales.createdBy);
            await m.addColumn(saleItems, saleItems.returnedQty);
            await m.addColumn(purchases, purchases.createdBy);
            await m.addColumn(expenses, expenses.createdBy);
            await m.addColumn(cashTxns, cashTxns.createdBy);
            await m.addColumn(ledgerEntries, ledgerEntries.createdBy);
          }
          if (from < 3) {
            // v3: website order/product links, and change tracking for Google Drive sync.
            await m.createTable(extLinks);
          }
        },
        beforeOpen: (details) async {
          await customStatement('PRAGMA foreign_keys = ON');
          // Sync tables and triggers are plain SQL, (re)installed on every open.
          await SyncSchema.install(this);
          idBase = await SyncSchema.idBase(this);
        },
      );

  Future<void> _createIndexes() async {
    const statements = [
      'CREATE INDEX IF NOT EXISTS idx_products_barcode ON products (barcode)',
      'CREATE INDEX IF NOT EXISTS idx_products_name ON products (name)',
      'CREATE INDEX IF NOT EXISTS idx_contacts_phone ON contacts (phone)',
      'CREATE INDEX IF NOT EXISTS idx_ledger_contact ON ledger_entries (contact_id, date)',
      'CREATE INDEX IF NOT EXISTS idx_ledger_ref ON ledger_entries (ref_type, ref_id)',
      'CREATE INDEX IF NOT EXISTS idx_cash_account ON cash_txns (account_id, date)',
      'CREATE INDEX IF NOT EXISTS idx_cash_ref ON cash_txns (ref_type, ref_id)',
      'CREATE INDEX IF NOT EXISTS idx_sales_date ON sales (date)',
      'CREATE INDEX IF NOT EXISTS idx_sales_status ON sales (channel, status)',
      'CREATE INDEX IF NOT EXISTS idx_sales_phone ON sales (ship_phone)',
      'CREATE INDEX IF NOT EXISTS idx_sale_items_sale ON sale_items (sale_id)',
      'CREATE INDEX IF NOT EXISTS idx_sale_items_product ON sale_items (product_id)',
      'CREATE INDEX IF NOT EXISTS idx_purchase_items_purchase ON purchase_items (purchase_id)',
      'CREATE INDEX IF NOT EXISTS idx_stock_moves_product ON stock_moves (product_id, date)',
      'CREATE INDEX IF NOT EXISTS idx_expenses_date ON expenses (date)',
      'CREATE INDEX IF NOT EXISTS idx_shipments_sale ON shipments (sale_id)',
    ];
    for (final s in statements) {
      await customStatement(s);
    }
  }
}
