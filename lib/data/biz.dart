import 'database.dart';
import 'repos/cash_repo.dart';
import 'repos/contact_repo.dart';
import 'repos/expense_repo.dart';
import 'repos/order_repo.dart';
import 'repos/product_repo.dart';
import 'repos/purchase_repo.dart';
import 'repos/report_repo.dart';
import 'repos/sale_repo.dart';
import 'repos/settings_repo.dart';
import 'repos/staff_repo.dart';

export 'database.dart';
export 'repos/cash_repo.dart';
export 'repos/contact_repo.dart';
export 'repos/expense_repo.dart';
export 'repos/order_repo.dart';
export 'repos/product_repo.dart';
export 'repos/purchase_repo.dart';
export 'repos/report_repo.dart';
export 'repos/sale_repo.dart';
export 'repos/settings_repo.dart';
export 'repos/staff_repo.dart';

/// Everything one business (one database file) can do.
class Biz {
  final AppDatabase db;
  Biz(this.db);

  late final settings = SettingsRepo(db);
  late final products = ProductRepo(db);
  late final cash = CashRepo(db);
  late final contacts = ContactRepo(db, cash);
  late final expenses = ExpenseRepo(db, cash);
  late final sales = SaleRepo(db, settings, products, contacts, cash);
  late final orders = OrderRepo(db, settings, sales, contacts, cash, expenses);
  late final purchases = PurchaseRepo(db, settings, products, contacts, cash);
  late final reports = ReportRepo(db);
  late final staff = StaffRepo(db);
}
