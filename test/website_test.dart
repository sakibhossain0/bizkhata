import 'dart:convert';

import 'package:bizkhata/data/biz.dart';
import 'package:bizkhata/data/seed.dart';
import 'package:bizkhata/web/connectors.dart';
import 'package:bizkhata/web/website_sync.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// A fake WooCommerce store: tests change [orders] / [products] between runs.
class FakeWoo {
  List<Map<String, dynamic>> orders = [];
  List<Map<String, dynamic>> products = [];
  final requests = <Uri>[];

  MockClient get client => MockClient((req) async {
        requests.add(req.url);
        if (req.url.queryParameters['consumer_key'] != 'ck_test') return http.Response('{"code":"woocommerce_rest_cannot_view"}', 401);
        final path = req.url.path;
        final body = path.endsWith('/orders') ? orders : (path.endsWith('/products') ? products : null);
        if (body == null) return http.Response('[]', 404);
        return http.Response(jsonEncode(body), 200, headers: {'x-wp-totalpages': '1', 'x-wp-total': '${body.length}'});
      });
}

Map<String, dynamic> wooOrder(int id, String status,
        {required List<Map<String, dynamic>> lines,
        String total = '840',
        String shipping = '60',
        String payment = 'cod',
        String? paid,
        String modified = '2026-11-09T10:00:00',
        List<Map<String, dynamic>> fees = const []}) =>
    {
      'id': id,
      'number': '$id',
      'status': status,
      'date_created_gmt': '2026-11-09T09:00:00',
      'date_modified_gmt': modified,
      'total': total,
      'shipping_total': shipping,
      'discount_total': '0',
      'total_tax': '0',
      'payment_method': payment,
      'payment_method_title': payment == 'cod' ? 'Cash on delivery' : 'bKash',
      'date_paid_gmt': paid,
      'customer_note': '',
      'billing': {'first_name': 'Rahim', 'last_name': 'Uddin', 'phone': '01711000001', 'address_1': 'Mirpur 10', 'city': 'Dhaka'},
      'shipping': {'first_name': '', 'last_name': '', 'address_1': '', 'city': ''},
      'line_items': lines,
      'fee_lines': fees,
    };

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late Biz biz;
  late FakeWoo woo;
  late int riceId;
  late int oilId;
  final cfg = WebsiteConfig(
      url: 'shop.example', key: 'ck_test', secret: 'cs_test', importFrom: DateTime.utc(2026, 11, 1), enabled: true);

  Future<WebsiteReport> run([WebsiteConfig? c]) =>
      WebsiteSync(biz, (c ?? cfg).connector(client: woo.client)).run(c ?? cfg);

  setUp(() async {
    biz = Biz(AppDatabase(NativeDatabase.memory()));
    await seedBusiness(biz, name: 'Shop', typeId: 'grocery', bangla: false);
    riceId = await biz.products.create(const ProductInput(name: 'Rice 5kg', sku: 'RICE5', unit: 'bag', salePrice: 390), openingStock: 50);
    oilId = await biz.products.create(const ProductInput(name: 'Oil', unit: 'pcs', salePrice: 200), openingStock: 20);
    woo = FakeWoo()
      ..orders = [
        wooOrder(101, 'processing', lines: [
          {'product_id': 11, 'variation_id': 0, 'sku': 'RICE5', 'name': 'Rice 5kg', 'quantity': 2, 'subtotal': '780'},
        ]),
        wooOrder(102, 'completed',
            total: '260', payment: 'bkash', paid: '2026-11-09T09:05:00', lines: [
              {'product_id': 12, 'variation_id': 0, 'sku': '', 'name': 'Oil', 'quantity': 1, 'subtotal': '200'},
            ]),
        wooOrder(103, 'pending', payment: 'bkash', lines: [
          {'product_id': 11, 'variation_id': 0, 'sku': 'RICE5', 'name': 'Rice 5kg', 'quantity': 1, 'subtotal': '390'},
        ]),
        wooOrder(104, 'cancelled', lines: [
          {'product_id': 11, 'variation_id': 0, 'sku': 'RICE5', 'name': 'Rice 5kg', 'quantity': 1, 'subtotal': '390'},
        ]),
      ]
      ..products = [
        {'id': 11, 'name': 'Rice 5kg', 'sku': 'RICE5', 'type': 'simple', 'price': '395', 'manage_stock': true, 'stock_quantity': 30, 'date_modified_gmt': '2026-11-09T10:00:00'},
        {'id': 12, 'name': 'Oil', 'sku': '', 'type': 'simple', 'price': '205', 'manage_stock': true, 'stock_quantity': 10, 'date_modified_gmt': '2026-11-09T10:00:00'},
      ];
  });

  tearDown(() => biz.db.close());

  Future<List<Sale>> online() => (biz.db.select(biz.db.sales)..where((t) => t.channel.equals('online'))).get();

  test('new website orders arrive as online orders, matched to products, with the website totals', () async {
    final rep = await run();
    expect(rep.created, 2);
    expect(rep.skipped, 2, reason: 'unpaid and cancelled orders are not brought in');
    final orders = await online();
    expect(orders, hasLength(2));
    final o101 = orders.firstWhere((s) => (s.note ?? '').contains('#101'));
    expect(o101.status, 'pending');
    expect(o101.total, 840);
    expect(o101.deliveryCharge, 60);
    expect(o101.paid, 0);
    expect(o101.shipPhone, '01711000001');
    final items = await (biz.db.select(biz.db.saleItems)..where((t) => t.saleId.equals(o101.id))).get();
    expect(items.single.productId, riceId);

    final o102 = orders.firstWhere((s) => (s.note ?? '').contains('#102'));
    expect(o102.status, 'delivered', reason: 'completed on the website');
    expect(o102.paid, 260);
    final web = int.parse(await biz.settings.getOr(WebKeys.account, ''));
    expect(await biz.cash.balanceOf(web), 260, reason: 'paid online -> Website payments');

    // Prices follow the website; stock stays ours (counter sales still count).
    expect((await biz.products.byId(riceId))!.salePrice, 395);
    expect((await biz.products.byId(riceId))!.stock, 48);
    expect((await biz.products.byId(oilId))!.stock, 19);
    // One minute of overlap, so an order changed right at the cursor is never missed.
    expect(woo.requests.first.queryParameters['modified_after'], '2026-10-31T23:59:00');
  });

  test('running again brings nothing twice, and status changes on the website follow', () async {
    await run();
    await run();
    expect(await online(), hasLength(2));
    // The customer cancels #101 on the website.
    woo.orders[0] = wooOrder(101, 'cancelled', modified: '2026-11-09T12:00:00', lines: [
      {'product_id': 11, 'variation_id': 0, 'sku': 'RICE5', 'name': 'Rice 5kg', 'quantity': 2, 'subtotal': '780'},
    ]);
    final rep = await run();
    expect(rep.updated, 1);
    final o101 = (await online()).firstWhere((s) => (s.note ?? '').contains('#101'));
    expect(o101.status, 'cancelled');
    expect((await biz.products.byId(riceId))!.stock, 50, reason: 'cancelled goods go back to stock');
  });

  test('"stock comes from the website" copies the website stock', () async {
    final c = WebsiteConfig(
        url: 'shop.example', key: 'ck_test', secret: 'cs_test', importFrom: DateTime.utc(2026, 11, 1), stockFromWebsite: true, enabled: true);
    await run(c);
    expect((await biz.products.byId(riceId))!.stock, 30);
    expect((await biz.products.byId(oilId))!.stock, 10);
  });

  test('a website fee keeps the order total exactly as the website has it', () async {
    woo.orders = [
      wooOrder(105, 'processing', total: '900', lines: [
        {'product_id': 11, 'variation_id': 0, 'sku': 'RICE5', 'name': 'Rice 5kg', 'quantity': 2, 'subtotal': '780'},
      ], fees: [
        {'name': 'COD charge', 'total': '20'},
      ]),
    ];
    await run();
    final o = (await online()).single;
    expect(o.total, 900, reason: '780 + 20 fee + 60 delivery = 860, rest is "other charges"');
  });

  test('wrong keys are reported, not ignored', () async {
    final bad = WebsiteConfig(url: 'shop.example', key: 'nope', secret: 'x', enabled: true);
    expect(() => bad.connector(client: woo.client).test(), throwsA(isA<WebsiteException>().having((e) => e.code, 'code', 'auth')));
  });

  test('the BizKhata JSON format is read leniently', () {
    final o = JsonApiConnector.parseOrder({
      '_id': '65ab',
      'invoice': 'INV-1043',
      'status': 'Shipped',
      'createdAt': '2026-11-09T09:00:00+06:00',
      'customer': {'name': 'Karim', 'phone': '01811000002', 'address': 'Agrabad', 'city': 'Chattogram'},
      'items': [
        {'sku': 'TSHIRT-L', 'name': 'T-shirt L', 'quantity': '2', 'price': '450'},
      ],
      'delivery_charge': 120,
      'total': '1020',
      'advance': 200,
      'tracking_code': 'ST123',
    });
    expect(o.id, '65ab');
    expect(o.number, 'INV-1043');
    expect(o.phone, '01811000002');
    expect(o.lines.single.qty, 2);
    expect(o.lines.single.price, 450);
    expect(o.shipping, 120);
    expect(o.paid, 200);
    expect(o.created.toUtc(), DateTime.utc(2026, 11, 9, 3));
    expect(JsonApiConnector(url: 'x', key: 'y').mapStatus(o), WebStatus.shipped);
  });
}
