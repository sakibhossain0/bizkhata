import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';

import '../../core/util.dart';
import '../database.dart';

/// What a person may do. The owner can do everything; managers run the shop
/// day to day; cashiers sell and collect dues.
enum Role { owner, manager, cashier }

enum Cap {
  dashboard,
  reports,
  purchases,
  expenses,
  cashbox,
  suppliers,

  /// Add, edit, delete products and adjust stock.
  editProducts,

  /// See cost prices and profit.
  seeCost,

  /// Cancel or return a sale.
  returns,

  /// Delete khata entries, contacts and other records.
  delete,

  /// Open settings (shop profile, invoice, courier, SMS).
  settings,

  /// Owner PIN, staff, backup restore, delete business, switch business.
  ownerOnly,
}

const _managerCaps = {
  Cap.dashboard,
  Cap.reports,
  Cap.purchases,
  Cap.expenses,
  Cap.cashbox,
  Cap.suppliers,
  Cap.editProducts,
  Cap.seeCost,
  Cap.returns,
  Cap.delete,
  Cap.settings,
};

/// Who is using the app right now.
class Actor {
  final Role role;
  final String name;
  final int? staffId;
  const Actor._(this.role, this.name, this.staffId);

  static const owner = Actor._(Role.owner, '', null);
  factory Actor.staff(StaffUser u) => Actor._(u.role == 'manager' ? Role.manager : Role.cashier, u.name, u.id);

  bool get isOwner => role == Role.owner;

  /// Written to `created_by`; the owner is stored as null.
  String? get stamp => isOwner ? null : name;

  bool can(Cap c) => switch (role) {
        Role.owner => true,
        Role.manager => _managerCaps.contains(c),
        Role.cashier => false,
      };

  /// Pages this person may open; everything else sends them [home].
  bool canVisit(String path) {
    if (isOwner) return true;
    String first = path.split('/').where((s) => s.isNotEmpty).firstOrNull ?? '';
    return switch (first) {
      '' => can(Cap.dashboard),
      'pos' || 'sales' || 'orders' || 'products' || 'customers' => true,
      'purchases' => can(Cap.purchases),
      'suppliers' => can(Cap.suppliers),
      'expenses' => can(Cap.expenses),
      'cashbox' => can(Cap.cashbox),
      'reports' => can(Cap.reports),
      'settings' => can(Cap.settings),
      _ => false,
    };
  }

  String get home => can(Cap.dashboard) ? '/' : '/pos';
}

String _salt() {
  final r = Random.secure();
  return List.generate(8, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
}

/// `salt:sha256` so two staff with the same PIN get different hashes.
String hashStaffPin(String pin) {
  final salt = _salt();
  return '$salt:${sha256.convert(utf8.encode('bizkhata-staff:$salt:$pin'))}';
}

bool checkStaffPin(String stored, String pin) {
  final i = stored.indexOf(':');
  if (i <= 0) return false;
  final salt = stored.substring(0, i);
  return stored.substring(i + 1) == sha256.convert(utf8.encode('bizkhata-staff:$salt:$pin')).toString();
}

class StaffRepo {
  final AppDatabase db;
  StaffRepo(this.db);

  Stream<List<StaffUser>> watchAll() =>
      (db.select(db.users)..orderBy([(t) => OrderingTerm.desc(t.active), (t) => OrderingTerm.asc(t.name)])).watch();

  Future<List<StaffUser>> active() =>
      (db.select(db.users)..where((t) => t.active.equals(true))..orderBy([(t) => OrderingTerm.asc(t.name)])).get();

  Future<StaffUser?> byId(int id) => (db.select(db.users)..where((t) => t.id.equals(id))).getSingleOrNull();

  void _check(String name, String role) {
    if (name.trim().isEmpty) throw BizException('name_required');
    if (role != 'manager' && role != 'cashier') throw BizException('role_invalid');
  }

  Future<void> _uniqueName(String name, {int? except}) async {
    final all = await db.select(db.users).get();
    final n = name.trim().toLowerCase();
    if (all.any((u) => u.id != except && u.name.trim().toLowerCase() == n)) throw BizException('staff_exists');
  }

  Future<int> add({required String name, required String role, required String pin}) async {
    _check(name, role);
    if (pin.length < 4) throw BizException('pin_short');
    await _uniqueName(name);
    return db.into(db.users).insert(UsersCompanion.insert(name: name.trim(), pinHash: hashStaffPin(pin), role: Value(role)));
  }

  Future<void> update(int id, {required String name, required String role, String? newPin, bool? active}) async {
    _check(name, role);
    if (newPin != null && newPin.isNotEmpty && newPin.length < 4) throw BizException('pin_short');
    await _uniqueName(name, except: id);
    await (db.update(db.users)..where((t) => t.id.equals(id))).write(UsersCompanion(
      name: Value(name.trim()),
      role: Value(role),
      pinHash: newPin == null || newPin.isEmpty ? const Value.absent() : Value(hashStaffPin(newPin)),
      active: active == null ? const Value.absent() : Value(active),
    ));
  }

  Future<void> setActive(int id, bool active) =>
      (db.update(db.users)..where((t) => t.id.equals(id))).write(UsersCompanion(active: Value(active)));

  /// Past sales keep the name they were stamped with, so removing is safe.
  Future<void> remove(int id) => (db.delete(db.users)..where((t) => t.id.equals(id))).go();
}
