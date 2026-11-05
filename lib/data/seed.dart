import 'dart:math';

import '../core/util.dart';
import 'biz.dart';

class BusinessType {
  final String id;
  final String en;
  final String bn;
  final String icon; // emoji, shown on onboarding cards
  final List<(String, String)> categories; // (en, bn)
  final bool online;
  const BusinessType(this.id, this.en, this.bn, this.icon, this.categories, {this.online = false});
}

const businessTypes = <BusinessType>[
  BusinessType('grocery', 'Grocery / General store', 'মুদি / জেনারেল স্টোর', '🛒', [
    ('Rice & Grains', 'চাল-ডাল'),
    ('Oil & Spices', 'তেল-মসলা'),
    ('Snacks & Drinks', 'স্ন্যাকস ও পানীয়'),
    ('Toiletries', 'প্রসাধনী'),
    ('Household', 'গৃহস্থালি'),
  ]),
  BusinessType('pharmacy', 'Pharmacy', 'ফার্মেসি', '💊', [
    ('Tablets & Capsules', 'ট্যাবলেট ও ক্যাপসুল'),
    ('Syrups', 'সিরাপ'),
    ('Baby care', 'শিশু যত্ন'),
    ('Medical devices', 'মেডিকেল সরঞ্জাম'),
  ]),
  BusinessType('fashion', 'Clothing & Fashion', 'পোশাক ও ফ্যাশন', '👗', [
    ('Men', 'ছেলেদের'),
    ('Women', 'মেয়েদের'),
    ('Kids', 'শিশুদের'),
    ('Accessories', 'এক্সেসরিজ'),
  ]),
  BusinessType('electronics', 'Mobile & Electronics', 'মোবাইল ও ইলেকট্রনিক্স', '📱', [
    ('Mobile phones', 'মোবাইল ফোন'),
    ('Accessories', 'এক্সেসরিজ'),
    ('Chargers & Cables', 'চার্জার ও ক্যাবল'),
    ('Repair parts', 'রিপেয়ার পার্টস'),
  ]),
  BusinessType('online', 'Online / Facebook shop', 'অনলাইন / ফেসবুক শপ', '📦', [
    ('Best sellers', 'বেস্ট সেলার'),
    ('New arrivals', 'নতুন পণ্য'),
    ('Combo offers', 'কম্বো অফার'),
  ], online: true),
  BusinessType('restaurant', 'Restaurant & Food', 'রেস্টুরেন্ট ও খাবার', '🍛', [
    ('Meals', 'মিল'),
    ('Fast food', 'ফাস্ট ফুড'),
    ('Drinks', 'পানীয়'),
    ('Desserts', 'মিষ্টি'),
  ]),
  BusinessType('cosmetics', 'Cosmetics & Beauty', 'কসমেটিক্স ও বিউটি', '💄', [
    ('Skin care', 'স্কিন কেয়ার'),
    ('Makeup', 'মেকআপ'),
    ('Hair care', 'হেয়ার কেয়ার'),
    ('Fragrance', 'সুগন্ধি'),
  ]),
  BusinessType('hardware', 'Hardware & Building', 'হার্ডওয়্যার ও নির্মাণ', '🔧', [
    ('Tools', 'যন্ত্রপাতি'),
    ('Electrical', 'ইলেকট্রিক্যাল'),
    ('Sanitary', 'স্যানিটারি'),
    ('Paint', 'রং'),
  ]),
  BusinessType('stationery', 'Stationery & Books', 'স্টেশনারি ও বই', '📚', [
    ('Books', 'বই'),
    ('Pens & Paper', 'কলম ও কাগজ'),
    ('School items', 'স্কুল সামগ্রী'),
  ]),
  BusinessType('wholesale', 'Wholesale / Distributor', 'পাইকারি / ডিস্ট্রিবিউটর', '🏬', [
    ('Fast moving', 'দ্রুত বিক্রিত'),
    ('Bulk items', 'বাল্ক পণ্য'),
  ]),
  BusinessType('service', 'Service business', 'সার্ভিস ব্যবসা', '🛠️', [
    ('Services', 'সার্ভিস'),
    ('Parts', 'পার্টস'),
  ]),
  BusinessType('other', 'Other business', 'অন্যান্য ব্যবসা', '🏪', [
    ('General', 'সাধারণ'),
  ]),
];

BusinessType businessTypeById(String id) =>
    businessTypes.firstWhere((t) => t.id == id, orElse: () => businessTypes.last);

const expenseCategorySeeds = <(String, String)>[
  ('Rent', 'দোকান ভাড়া'),
  ('Salary', 'বেতন'),
  ('Electricity', 'বিদ্যুৎ বিল'),
  ('Internet & Phone', 'ইন্টারনেট ও ফোন'),
  ('Transport', 'যাতায়াত'),
  ('Tea & Snacks', 'চা-নাস্তা'),
  ('Packaging', 'প্যাকেজিং'),
  ('Marketing / Boost', 'মার্কেটিং / বুস্ট'),
  ('Repair', 'মেরামত'),
  ('Courier charge', 'কুরিয়ার চার্জ'),
  ('Others', 'অন্যান্য'),
];

const unitSuggestions = [
  'pcs', 'kg', 'g', 'litre', 'ml', 'box', 'packet', 'dozen', 'pair', 'set', 'metre', 'feet', 'bottle', 'bag', 'carton', 'hour'
];

/// First-run setup of a brand new business database.
Future<void> seedBusiness(
  Biz biz, {
  required String name,
  required String typeId,
  String phone = '',
  String address = '',
  required bool bangla,
}) async {
  final type = businessTypeById(typeId);
  await biz.db.transaction(() async {
    await biz.settings.setMany({
      K.businessName: name.trim(),
      K.businessType: type.id,
      K.phone: normalizePhone(phone).isEmpty ? phone.trim() : normalizePhone(phone),
      K.address: address.trim(),
      K.invoicePrefix: 'INV-',
      K.paperSize: '80',
      K.receiptFooter: bangla ? 'আমাদের সাথে কেনাকাটার জন্য ধন্যবাদ!' : 'Thank you for shopping with us!',
      K.onlineEnabled: type.online ? '1' : '0',
      K.allowNegativeStock: '1',
    });
    for (final (en, bn) in type.categories) {
      await biz.products.addCategory(bangla ? bn : en);
    }
    for (final (en, bn) in expenseCategorySeeds) {
      // Courier charge keeps its English key: order settlement posts to it.
      await biz.expenses.ensureCategory(en == 'Courier charge' ? en : (bangla ? bn : en));
    }
    await biz.cash.createAccount(bangla ? 'ক্যাশ' : 'Cash', kind: 'cash');
    await biz.cash.createAccount(bangla ? 'বিকাশ' : 'bKash', kind: 'mobile');
    await biz.cash.createAccount(bangla ? 'নগদ' : 'Nagad', kind: 'mobile');
    await biz.cash.createAccount(bangla ? 'ব্যাংক' : 'Bank', kind: 'bank');
  });
}

/// A realistic two-week history so a new user can explore every screen.
Future<void> seedDemoData(Biz biz, {required bool bangla}) async {
  final rnd = Random(42);
  final cats = await biz.products.watchCategories().first;
  int? cat(int i) => cats.isEmpty ? null : cats[i % cats.length].id;

  final productDefs = <(String, String, double, double, double, String)>[
    // (en, bn, cost, price, opening stock, unit)
    ('Miniket Rice 5kg', 'মিনিকেট চাল ৫ কেজি', 340, 390, 40, 'bag'),
    ('Soybean Oil 1L', 'সয়াবিন তেল ১ লিটার', 165, 185, 60, 'bottle'),
    ('Red Lentils 1kg', 'মসুর ডাল ১ কেজি', 110, 135, 35, 'kg'),
    ('Sugar 1kg', 'চিনি ১ কেজি', 118, 130, 50, 'kg'),
    ('Tea 400g', 'চা পাতা ৪০০ গ্রাম', 190, 230, 24, 'packet'),
    ('Biscuits Family Pack', 'বিস্কুট ফ্যামিলি প্যাক', 85, 110, 48, 'packet'),
    ('Detergent 1kg', 'ডিটারজেন্ট ১ কেজি', 140, 170, 30, 'packet'),
    ('Toothpaste 150g', 'টুথপেস্ট ১৫০ গ্রাম', 95, 120, 6, 'pcs'),
    ('Bath Soap', 'গোসলের সাবান', 42, 55, 80, 'pcs'),
    ('Mineral Water 1.5L', 'মিনারেল ওয়াটার ১.৫ লি.', 22, 30, 4, 'bottle'),
    ('Instant Noodles', 'ইনস্ট্যান্ট নুডলস', 18, 25, 120, 'packet'),
    ('Powdered Milk 500g', 'গুঁড়া দুধ ৫০০ গ্রাম', 380, 430, 3, 'packet'),
  ];
  final productIds = <int>[];
  var i = 0;
  for (final (en, bn, cost, price, stock, unit) in productDefs) {
    productIds.add(await biz.products.create(
      ProductInput(
        name: bangla ? bn : en,
        sku: 'P${(1001 + i)}',
        barcode: '89000${(10001 + i)}',
        categoryId: cat(i),
        unit: unit,
        costPrice: cost,
        salePrice: price,
        lowStock: 8,
      ),
      openingStock: stock,
      openingDate: DateTime.now().subtract(const Duration(days: 15)),
    ));
    i++;
  }

  final customers = <int>[];
  for (final (n, p) in [
    (bangla ? 'রহিম উদ্দিন' : 'Rahim Uddin', '01711000001'),
    (bangla ? 'করিম স্টোর' : 'Karim Store', '01811000002'),
    (bangla ? 'সালমা বেগম' : 'Salma Begum', '01911000003'),
    (bangla ? 'জাহিদ হাসান' : 'Zahid Hasan', '01611000004'),
  ]) {
    customers.add(await biz.contacts.create(type: 'customer', name: n, phone: p, address: bangla ? 'মিরপুর, ঢাকা' : 'Mirpur, Dhaka'));
  }
  final supplier = await biz.contacts.create(
      type: 'supplier', name: bangla ? 'মেসার্স আল-আমিন ট্রেডার্স' : 'M/S Al-Amin Traders', phone: '01511000005', openingBalance: -2500);
  await biz.contacts.create(type: 'supplier', name: bangla ? 'ঢাকা ডিস্ট্রিবিউশন' : 'Dhaka Distribution', phone: '01311000006');

  final accounts = await biz.cash.accounts();
  final cashId = accounts.first.id;
  final bkashId = accounts.length > 1 ? accounts[1].id : cashId;
  final products = [for (final id in productIds) (await biz.products.byId(id))!];

  final now = DateTime.now();
  await biz.cash.manual(
    accountId: cashId,
    cashIn: true,
    amount: 20000,
    note: bangla ? 'মালিকের মূলধন' : 'Owner capital',
    date: now.subtract(const Duration(days: 15)),
  );
  for (var day = 13; day >= 0; day--) {
    final date = DateTime(now.year, now.month, now.day - day, 10);
    final salesToday = 2 + rnd.nextInt(4);
    for (var s = 0; s < salesToday; s++) {
      final lines = <CartLine>[];
      final count = 1 + rnd.nextInt(3);
      for (var k = 0; k < count; k++) {
        final p = (await biz.products.byId(products[rnd.nextInt(products.length)].id))!;
        final q = (1 + rnd.nextInt(2)).toDouble();
        // Only sell what is on the shelf, like a real shop.
        if (lines.any((l) => l.productId == p.id) || p.stock < q) continue;
        lines.add(CartLine(productId: p.id, name: p.name, qty: q, price: p.salePrice, unit: p.unit));
      }
      if (lines.isEmpty) continue;
      final total = computeTotals(lines).total;
      final onCredit = rnd.nextInt(6) == 0;
      final customer = onCredit || rnd.nextBool() ? customers[rnd.nextInt(customers.length)] : null;
      await biz.sales.createSale(
        lines: lines,
        contactId: customer,
        paid: onCredit ? (total * 0.5).roundToDouble() : total,
        accountId: rnd.nextInt(4) == 0 ? bkashId : cashId,
        date: date.add(Duration(minutes: 30 * s + rnd.nextInt(25))),
      );
    }
    if (day % 4 == 0) {
      await biz.expenses.add(
        category: bangla ? 'চা-নাস্তা' : 'Tea & Snacks',
        amount: 120 + rnd.nextInt(5) * 20.0,
        accountId: cashId,
        date: date.add(const Duration(hours: 5)),
      );
    }
  }
  await biz.expenses.add(
      category: bangla ? 'দোকান ভাড়া' : 'Rent', amount: 8000, accountId: cashId, date: DateTime(now.year, now.month, 1, 11));
  await biz.expenses.add(
      category: bangla ? 'বিদ্যুৎ বিল' : 'Electricity', amount: 1450, accountId: bkashId, date: now.subtract(const Duration(days: 3)));

  await biz.purchases.create(
    supplierId: supplier,
    lines: [
      PurchaseLine(productId: products[0].id, name: products[0].name, qty: 10, unitCost: 335),
      PurchaseLine(productId: products[1].id, name: products[1].name, qty: 24, unitCost: 163),
    ],
    paid: 5000,
    accountId: cashId,
    date: now.subtract(const Duration(days: 5)),
  );

  // A few delivery orders in different stages.
  await biz.settings.setFlag(K.onlineEnabled, true);
  await biz.settings.setJson(K.courierConfig, {'default': 'steadfast', 'testMode': true, 'deliveryFee': 60, 'returnFee': 30});
  for (final (n, p, a, st) in [
    (bangla ? 'নুসরাত জাহান' : 'Nusrat Jahan', '01722000011', bangla ? 'বাড়ি ১২, রোড ৫, ধানমন্ডি' : 'House 12, Road 5, Dhanmondi', 'pending'),
    (bangla ? 'তানভীর আহমেদ' : 'Tanvir Ahmed', '01822000012', bangla ? 'সেক্টর ৭, উত্তরা' : 'Sector 7, Uttara', 'confirmed'),
    (bangla ? 'মিতু আক্তার' : 'Mitu Akter', '01922000013', bangla ? 'আগ্রাবাদ, চট্টগ্রাম' : 'Agrabad, Chattogram', 'delivered'),
  ]) {
    var pr = (await biz.products.byId(products[rnd.nextInt(products.length)].id))!;
    if (pr.stock < 2) pr = (await biz.products.byId(products[0].id))!;
    final id = await biz.orders.create(
      name: n,
      phone: p,
      address: a,
      area: a.split(',').length > 1 ? a.split(',')[a.split(',').length - 1].trim() : null,
      city: a.contains('Chattogram') || a.contains('চট্টগ্রাম') ? 'Chattogram' : 'Dhaka',
      lines: [CartLine(productId: pr.id, name: pr.name, qty: 2, price: pr.salePrice, unit: pr.unit)],
      deliveryCharge: a.contains('Chattogram') || a.contains('চট্টগ্রাম') ? 120 : 60,
      date: now.subtract(const Duration(hours: 20)),
    );
    if (st == 'confirmed') await biz.orders.confirm(id);
    if (st == 'delivered') {
      await biz.orders.book(id, 'steadfast');
      await biz.orders.markDelivered(id, fee: 120);
    }
  }
}
