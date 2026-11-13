import 'package:drift/drift.dart';

import '../../core/util.dart';
import '../database.dart';
import 'cash_repo.dart';

class ContactWithBalance {
  final Contact contact;

  /// > 0: they owe us (receivable). < 0: we owe them (payable).
  final double balance;
  final DateTime? lastActivity;
  const ContactWithBalance(this.contact, this.balance, this.lastActivity);
}

class LedgerLine {
  final LedgerEntry entry;

  /// Balance after this entry, oldest first.
  final double running;
  const LedgerLine(this.entry, this.running);
}

enum ContactSort { name, balanceDesc, recent }

class ContactRepo {
  final AppDatabase db;
  final CashRepo cash;
  ContactRepo(this.db, this.cash);

  Stream<List<ContactWithBalance>> watchContacts(String type,
      {String query = '', ContactSort sort = ContactSort.recent, bool onlyWithBalance = false}) {
    final term = query.trim();
    final where = StringBuffer('c.type = ? AND c.active = 1');
    final vars = <Variable>[Variable.withString(type)];
    if (term.isNotEmpty) {
      where.write(' AND (c.name LIKE ? OR c.phone LIKE ?)');
      vars
        ..add(Variable.withString('%$term%'))
        ..add(Variable.withString('%${normalizePhone(term).isEmpty ? term : normalizePhone(term)}%'));
    }
    final having = onlyWithBalance ? 'WHERE ABS(balance) >= 0.01' : '';
    final order = switch (sort) {
      ContactSort.name => 'name COLLATE NOCASE ASC',
      ContactSort.balanceDesc => 'ABS(balance) DESC',
      ContactSort.recent => 'COALESCE(last_at, created_at) DESC',
    };
    return db
        .customSelect(
          '''SELECT * FROM (
               SELECT c.*,
                 COALESCE((SELECT SUM(amount) FROM ledger_entries l WHERE l.contact_id = c.id), 0) AS balance,
                 (SELECT MAX(date) FROM ledger_entries l WHERE l.contact_id = c.id) AS last_at
               FROM contacts c WHERE $where
             ) $having ORDER BY $order''',
          variables: vars,
          readsFrom: {db.contacts, db.ledgerEntries},
        )
        .watch()
        .map((rows) => rows.map((r) {
              final c = db.contacts.map(r.data);
              final last = r.readNullable<int>('last_at');
              return ContactWithBalance(
                c,
                r2(r.read<double>('balance')),
                last == null ? null : DateTime.fromMillisecondsSinceEpoch(last * 1000),
              );
            }).toList());
  }

  Future<List<Contact>> search(String type, String query, {int limit = 20}) {
    final term = query.trim();
    final q = db.select(db.contacts)..where((t) => t.type.equals(type) & t.active.equals(true));
    if (term.isNotEmpty) {
      final phone = normalizePhone(term);
      q.where((t) => t.name.like('%$term%') | t.phone.like('%${phone.isEmpty ? term : phone}%'));
    }
    q
      ..orderBy([(t) => OrderingTerm.asc(t.name)])
      ..limit(limit);
    return q.get();
  }

  Future<Contact?> byId(int id) => (db.select(db.contacts)..where((t) => t.id.equals(id))).getSingleOrNull();

  Stream<Contact?> watchById(int id) =>
      (db.select(db.contacts)..where((t) => t.id.equals(id))).watchSingleOrNull();

  Future<Contact?> byPhone(String type, String phone) async {
    final p = normalizePhone(phone);
    if (p.isEmpty) return null;
    final rows = await (db.select(db.contacts)
          ..where((t) => t.type.equals(type) & t.phone.equals(p) & t.active.equals(true))
          ..limit(1))
        .get();
    return rows.isEmpty ? null : rows.first;
  }

  /// [openingBalance] > 0 means they already owe us; < 0 means we owe them.
  Future<int> create({
    required String type,
    required String name,
    String? phone,
    String? address,
    String? email,
    String? note,
    double openingBalance = 0,
  }) =>
      db.transaction(() async {
        if (name.trim().isEmpty) throw BizException('name_required');
        final p = normalizePhone(phone);
        if (p.isNotEmpty) {
          final dup = await byPhone(type, p);
          if (dup != null) throw BizException('phone_exists');
        }
        final id = await db.insertRow(db.contacts, ContactsCompanion.insert(
              type: type,
              name: name.trim(),
              phone: Value(p.isEmpty ? null : p),
              address: Value(_blank(address)),
              email: Value(_blank(email)),
              note: Value(_blank(note)),
            ));
        if (openingBalance != 0) {
          await db.insertRow(db.ledgerEntries, LedgerEntriesCompanion.insert(
                contactId: id,
                date: DateTime.now(),
                kind: 'opening',
                amount: r2(openingBalance),
                createdBy: Value(db.actor),
              ));
        }
        return id;
      });

  static const importHeaders = ['name', 'phone', 'address', 'email', 'balance', 'note'];

  /// Bulk import customers or suppliers from a CSV sheet (header row required,
  /// columns in any order). `balance` > 0 means they owe us, < 0 we owe them;
  /// it becomes the opening khata entry. Existing phones are skipped.
  Future<({int created, int skipped})> importCsv(String type, List<List<String>> rows) async {
    if (rows.length < 2) throw BizException('csv_empty');
    final head = rows.first.map((h) => h.trim().toLowerCase().replaceAll(' ', '_')).toList();
    int col(List<String> names) => head.indexWhere((h) => names.contains(h));
    final iName = col(['name', 'customer', 'supplier', 'নাম']);
    if (iName < 0) throw BizException('name_required');
    final iPhone = col(['phone', 'mobile', 'number', 'ফোন', 'মোবাইল']);
    final iAddress = col(['address', 'ঠিকানা']);
    final iEmail = col(['email']);
    final iBalance = col(['balance', 'due', 'opening', 'বাকি']);
    final iNote = col(['note', 'notes']);
    String cell(List<String> r, int i) => i >= 0 && i < r.length ? r[i].trim() : '';
    var created = 0, skipped = 0;
    for (final r in rows.skip(1)) {
      final name = cell(r, iName);
      if (name.isEmpty) {
        skipped++;
        continue;
      }
      try {
        await create(
          type: type,
          name: name,
          phone: cell(r, iPhone),
          address: cell(r, iAddress),
          email: cell(r, iEmail),
          note: cell(r, iNote),
          openingBalance: parseNum(cell(r, iBalance)),
        );
        created++;
      } on BizException {
        skipped++; // duplicate phone and the like: keep going
      }
    }
    return (created: created, skipped: skipped);
  }

  /// Rows for a CSV export in the same shape the importer reads.
  Future<List<List<Object?>>> exportRows(String type) async {
    final list = await watchContacts(type).first;
    return [
      importHeaders,
      for (final c in list) [c.contact.name, c.contact.phone ?? '', c.contact.address ?? '', c.contact.email ?? '', c.balance, c.contact.note ?? ''],
    ];
  }

  /// Find a customer by phone or create one — used by online orders.
  Future<int> findOrCreateCustomer({required String name, required String phone, String? address}) async {
    final existing = await byPhone('customer', phone);
    if (existing != null) {
      if ((existing.address == null || existing.address!.isEmpty) && (address?.trim().isNotEmpty ?? false)) {
        await (db.update(db.contacts)..where((t) => t.id.equals(existing.id)))
            .write(ContactsCompanion(address: Value(address!.trim())));
      }
      return existing.id;
    }
    return create(type: 'customer', name: name, phone: phone, address: address);
  }

  /// The active customer saved under exactly this name, ignoring outer spaces
  /// and letter case. When several share the name, [contact] is null and
  /// [ambiguous] is true: picking one would be a guess at whose khata it is.
  Future<({Contact? contact, bool ambiguous})> customerByName(String name) async {
    final n = name.trim();
    if (n.isEmpty) return (contact: null, ambiguous: false);
    final rows = await (db.select(db.contacts)
          ..where((t) =>
              t.type.equals('customer') &
              t.active.equals(true) &
              // Both sides through SQLite's lower() so they fold case the same way.
              t.name.trim().lower().equalsExp(Variable<String>(n).lower()))
          ..limit(2))
        .get();
    return (contact: rows.length == 1 ? rows.first : null, ambiguous: rows.length > 1);
  }

  /// The customer for a counter sale from the name and phone typed at the
  /// till. A phone finds the customer it belongs to or saves a new one; a name
  /// alone reuses the customer saved under that name, else saves a new one.
  /// A name several customers share is refused (`name_ambiguous`).
  Future<int> customerFor({String? name, String? phone}) async {
    final n = name?.trim() ?? '';
    final p = normalizePhone(phone);
    if (p.isNotEmpty) return findOrCreateCustomer(name: n.isEmpty ? p : n, phone: p);
    if (n.isEmpty) throw BizException('name_required');
    final same = await customerByName(n);
    if (same.ambiguous) throw BizException('name_ambiguous');
    return same.contact?.id ?? await create(type: 'customer', name: n);
  }

  /// Saves a phone number on a contact and touches nothing else ([update]
  /// rewrites every field). Refuses a number another active contact of the
  /// same kind already has.
  Future<void> setPhone(int id, String phone) => db.transaction(() async {
        final p = normalizePhone(phone);
        if (p.isEmpty) throw BizException('phone_invalid');
        final c = await byId(id);
        if (c == null) throw BizException('not_found');
        final owner = await byPhone(c.type, p);
        if (owner != null && owner.id != id) throw BizException('phone_exists');
        await (db.update(db.contacts)..where((t) => t.id.equals(id))).write(ContactsCompanion(phone: Value(p)));
      });

  Future<void> update(int id, {required String name, String? phone, String? address, String? email, String? note}) async {
    if (name.trim().isEmpty) throw BizException('name_required');
    final p = normalizePhone(phone);
    await (db.update(db.contacts)..where((t) => t.id.equals(id))).write(ContactsCompanion(
          name: Value(name.trim()),
          phone: Value(p.isEmpty ? null : p),
          address: Value(_blank(address)),
          email: Value(_blank(email)),
          note: Value(_blank(note)),
        ));
  }

  Future<double> balanceOf(int contactId) async {
    final r = await db.customSelect(
      'SELECT COALESCE(SUM(amount), 0) AS b FROM ledger_entries WHERE contact_id = ?',
      variables: [Variable.withInt(contactId)],
    ).getSingle();
    return r2(r.read<double>('b'));
  }

  Stream<double> watchBalance(int contactId) => db
      .customSelect(
        'SELECT COALESCE(SUM(amount), 0) AS b FROM ledger_entries WHERE contact_id = ?',
        variables: [Variable.withInt(contactId)],
        readsFrom: {db.ledgerEntries},
      )
      .watchSingle()
      .map((r) => r2(r.read<double>('b')));

  /// Archive a contact. Refuses while money is still owed either way.
  Future<void> archive(int id) async {
    if ((await balanceOf(id)).abs() >= 0.01) throw BizException('contact_has_balance');
    await (db.update(db.contacts)..where((t) => t.id.equals(id))).write(const ContactsCompanion(active: Value(false)));
  }

  /// Newest first, with running balance computed oldest → newest.
  Stream<List<LedgerLine>> watchLedger(int contactId) => (db.select(db.ledgerEntries)
            ..where((t) => t.contactId.equals(contactId))
            ..orderBy([(t) => OrderingTerm.asc(t.date), (t) => OrderingTerm.asc(t.id)]))
          .watch()
          .map((rows) {
        var running = 0.0;
        final lines = <LedgerLine>[];
        for (final e in rows) {
          running = r2(running + e.amount);
          lines.add(LedgerLine(e, running));
        }
        return lines.reversed.toList();
      });

  /// TallyKhata-style manual entry.
  ///  gave (দিলাম): balance goes up   — you handed over goods/cash on credit, or paid a supplier.
  ///  got  (পেলাম): balance goes down — customer paid you, or supplier gave goods on credit.
  /// When [accountId] is set, real money moved and the cashbox is updated.
  Future<int> addEntry({
    required int contactId,
    required bool gave,
    required double amount,
    int? accountId,
    String? note,
    DateTime? date,
  }) =>
      db.transaction(() async {
        final amt = r2(amount);
        if (amt <= 0) throw BizException('amount_positive');
        final when = date ?? DateTime.now();
        final id = await db.insertRow(db.ledgerEntries, LedgerEntriesCompanion.insert(
              contactId: contactId,
              date: when,
              kind: gave ? 'gave' : 'got',
              amount: gave ? amt : -amt,
              accountId: Value(accountId),
              note: Value(_blank(note)),
              createdBy: Value(db.actor),
            ));
        if (accountId != null) {
          await cash.add(
            accountId: accountId,
            direction: gave ? -1 : 1,
            amount: amt,
            source: 'khata',
            refType: 'ledger',
            refId: id,
            contactId: contactId,
            note: note,
            date: when,
          );
        }
        return id;
      });

  /// Only hand-made entries can be deleted; sale/purchase entries belong to
  /// their document and are reversed through it.
  Future<void> deleteEntry(int entryId) => db.transaction(() async {
        final e = await (db.select(db.ledgerEntries)..where((t) => t.id.equals(entryId))).getSingleOrNull();
        if (e == null) return;
        if (!const {'gave', 'got', 'opening'}.contains(e.kind)) throw BizException('entry_locked');
        await cash.deleteByRef('ledger', entryId);
        await (db.delete(db.ledgerEntries)..where((t) => t.id.equals(entryId))).go();
      });

  /// Low level, used inside other repos' transactions.
  Future<void> post({
    required int contactId,
    required String kind,
    required double amount,
    required String refType,
    required int refId,
    int? accountId,
    String? note,
    DateTime? date,
  }) async {
    if (amount == 0) return;
    await db.insertRow(db.ledgerEntries, LedgerEntriesCompanion.insert(
          contactId: contactId,
          date: date ?? DateTime.now(),
          kind: kind,
          amount: r2(amount),
          refType: Value(refType),
          refId: Value(refId),
          accountId: Value(accountId),
          note: Value(note),
          createdBy: Value(db.actor),
        ));
  }

  /// Total receivable (customers owe us) and payable (we owe), across all contacts.
  Stream<({double receivable, double payable})> watchTotals() => db
      .customSelect(
        '''SELECT
             COALESCE(SUM(CASE WHEN b > 0 THEN b END), 0) AS rec,
             COALESCE(-SUM(CASE WHEN b < 0 THEN b END), 0) AS pay
           FROM (SELECT SUM(amount) AS b FROM ledger_entries l
                 JOIN contacts c ON c.id = l.contact_id AND c.active = 1
                 GROUP BY l.contact_id)''',
        readsFrom: {db.ledgerEntries, db.contacts},
      )
      .watchSingle()
      .map((r) => (receivable: r2(r.read<double>('rec')), payable: r2(r.read<double>('pay'))));

  /// Stats for an online-order customer from our own history (fraud signal).
  Future<({int delivered, int returned, int cancelled, int pending})> orderHistory(String phone) async {
    final p = normalizePhone(phone);
    if (p.isEmpty) return (delivered: 0, returned: 0, cancelled: 0, pending: 0);
    final r = await db.customSelect(
      '''SELECT
           SUM(CASE WHEN status IN ('delivered','partial') THEN 1 ELSE 0 END) AS d,
           SUM(CASE WHEN status = 'returned' THEN 1 ELSE 0 END) AS r,
           SUM(CASE WHEN status = 'cancelled' THEN 1 ELSE 0 END) AS c,
           SUM(CASE WHEN status IN ('pending','confirmed','booked') THEN 1 ELSE 0 END) AS p
         FROM sales WHERE channel = 'online' AND ship_phone = ?''',
      variables: [Variable.withString(p)],
    ).getSingle();
    return (
      delivered: r.readNullable<int>('d') ?? 0,
      returned: r.readNullable<int>('r') ?? 0,
      cancelled: r.readNullable<int>('c') ?? 0,
      pending: r.readNullable<int>('p') ?? 0,
    );
  }
}

String? _blank(String? s) => (s == null || s.trim().isEmpty) ? null : s.trim();
