import 'dart:convert';

import 'package:bizkhata/web/connectors.dart';
import 'package:bizkhata/web/order_finder.dart';
import 'package:flutter_test/flutter_test.dart';

/// An order as a Mongo/Express admin panel returns it (the shape of the
/// shops BizKhata's owner builds), with look-alike fields that must NOT be
/// taken: the courier parcel's own name/phone/amount, the fraud check, notes.
Map<String, dynamic> mongoOrder(int i, String status, {String created = '2026-11-10T08:00:00.000Z'}) => {
      '_id': '66b0c0ffee00000000000${100 + i}',
      'user': null,
      'guestId': 'g$i',
      'items': [
        {
          'productId': '65aa0000000000000000000$i',
          'name': 'Remote car',
          'price': 1250,
          'qty': 1,
          'image': 'https://cdn.shop/car.jpg',
          'options': {'color': 'Red', 'colorLabel': 'Red', 'colorImage': 'https://cdn.shop/red.jpg', 'size': '', 'variant': ''},
        },
        {'productId': '65bb000000000000000000aa', 'name': 'Battery pack', 'price': 150, 'qty': 2, 'image': '', 'options': {}},
      ],
      'shipping': {
        'fullName': 'Rahim Uddin $i',
        'phone': '0171100000$i',
        'email': '',
        'address': 'House $i, Road 3, Mirpur',
        'thana': 'Mirpur',
        'city': 'Dhaka',
        'deliveryZone': 'inside',
        'area': '',
      },
      'deliveryFee': 70,
      'paymentMethod': 'cod',
      'paymentStatus': 'unpaid',
      'status': status,
      'total': 1620,
      'discount': 0,
      'invoiceNo': 'VM-10$i',
      'note': '',
      'noteAuthorName': 'Admin Karim',
      'fraudCheck': {'phone': '0171100000$i', 'ratio': 90, 'total': 10},
      'courier': {'provider': 'steadfast'},
      'steadfast': {
        'consignmentId': 1000 + i,
        'invoice': 'VM-10$i',
        'trackingCode': 'SFR10$i',
        'deliveryStatus': 'in_review',
        'codAmount': 1620,
        'createdAt': '2026-11-11T08:00:00.000Z',
        'events': [
          {'status': 'pending', 'at': '2026-11-11T08:00:00.000Z'},
        ],
      },
      'parcelBooked': {'name': 'Rahim Uddin $i', 'phone': '0171100000$i', 'address': 'x', 'cod': 1620},
      'createdAt': created,
      'updatedAt': '2026-11-11T09:00:00.000Z',
      '__v': 0,
    };

void main() {
  group('finds orders in what an admin panel loads', () {
    test('Mongo/Express admin: a bare array, nested shipping, items with options', () {
      final json = [mongoOrder(1, 'pending'), mongoOrder(2, 'shipped'), mongoOrder(3, 'delivered')];
      final found = findOrderLists(jsonDecode(jsonEncode(json)));
      expect(found, hasLength(1));
      final m = found.first.mapping;
      expect(found.first.path, '');
      expect(m.fields[OrderField.id], '_id');
      expect(m.fields[OrderField.number], 'invoiceNo');
      expect(m.fields[OrderField.phone], 'shipping.phone');
      expect(m.fields[OrderField.name], 'shipping.fullName');
      expect(m.fields[OrderField.address], 'shipping.address');
      expect(m.fields[OrderField.area], 'shipping.thana');
      expect(m.fields[OrderField.city], 'shipping.city');
      expect(m.fields[OrderField.total], 'total');
      expect(m.fields[OrderField.shipping], 'deliveryFee');
      expect(m.fields[OrderField.status], 'status');
      expect(m.fields[OrderField.created], 'createdAt');
      expect(m.fields[OrderField.updated], 'updatedAt');
      expect(m.fields[OrderField.tracking], 'steadfast.trackingCode');
      expect(m.fields[OrderField.courier], 'courier.provider');
      expect(m.fields[OrderField.payment], 'paymentMethod');
      expect(m.items, 'items');

      final o = found.first.orders()[1];
      expect(o.id, '66b0c0ffee00000000000102');
      expect(o.number, 'VM-102');
      expect(o.status, 'shipped');
      expect(o.phone, '01711000002');
      expect(o.name, 'Rahim Uddin 2');
      expect(o.total, 1620);
      expect(o.shipping, 70);
      expect(o.paid, 0);
      expect(o.tracking, 'SFR102');
      expect(o.created, DateTime.utc(2026, 11, 10, 8));
      expect(o.version, '2026-11-11T09:00:00.000Z');
      expect(o.lines.map((l) => '${l.qty} ${l.name} ${l.price}'), ['1.0 Remote car (Red) 1250.0', '2.0 Battery pack 150.0']);
      expect(o.lines.first.productId, '65aa00000000000000000002');
    });

    test('Laravel paginate: rows under "data", money as text, page count beside them', () {
      final json = {
        'current_page': 1,
        'data': [
          for (var i = 1; i <= 3; i++)
            {
              'id': 100 + i,
              'invoice_no': 'INV-10$i',
              'customer_name': 'Karim $i',
              'customer_phone': '+88018120000$i$i',
              'shipping_address': 'Road $i, Uttara',
              'grand_total': '1,540.00',
              'delivery_charge': '60.00',
              'order_status': 'Processing',
              'payment_status': 'Paid',
              'created_at': '2026-11-10 14:22:0$i',
              'order_details': [
                {'product_name': 'T-shirt', 'quantity': 2, 'unit_price': '740.00'},
              ],
            },
        ],
        'last_page': 3,
        'per_page': 15,
        'total': 40,
      };
      final found = findOrderLists(json);
      expect(found.first.path, 'data');
      final o = found.first.orders().first;
      expect(o.number, 'INV-101');
      expect(o.phone, '+8801812000011');
      expect(o.name, 'Karim 1');
      expect(o.address, 'Road 1, Uttara');
      expect(o.total, 1540);
      expect(o.shipping, 60);
      expect(o.paid, 1540, reason: 'payment_status Paid');
      expect(o.status, 'Processing');
      expect(localStatusOf(o.status), 'pending');
      expect(o.lines.single.price, 740);
      expect(pageInfo(json, 'data').lastPage, 3);
    });

    test('WooCommerce-like: empty shipping block, phone only under billing, first+last name', () {
      final json = [
        for (var i = 1; i <= 2; i++)
          {
            'id': 720 + i,
            'number': '${720 + i}',
            'status': 'processing',
            'date_created': '2026-11-10T10:00:00',
            'total': '1250.00',
            'shipping_total': '60.00',
            'discount_total': '0.00',
            'billing': {'first_name': 'Sadia', 'last_name': 'Akter $i', 'address_1': 'House $i', 'address_2': 'Dhanmondi', 'city': 'Dhaka', 'phone': '0191100000$i'},
            'shipping': {'first_name': 'Sadia', 'last_name': 'Akter $i', 'address_1': 'House $i', 'address_2': 'Dhanmondi', 'city': 'Dhaka', 'phone': ''},
            'line_items': [
              {'name': 'Puzzle', 'quantity': 1, 'price': 1190, 'sku': 'PZ-1', 'product_id': 55, 'total': '1190.00'},
            ],
            'payment_method_title': 'Cash on delivery',
          },
      ];
      final f = findOrderLists(json).single;
      final o = f.orders().last;
      expect(o.phone, '01911000002');
      expect(o.name, 'Sadia Akter 2');
      expect(o.address, 'House 2, Dhanmondi');
      expect(o.total, 1250);
      expect(o.lines.single.sku, 'PZ-1');
    });

    test('Shopify-like: "#1001" name is the number, paid when financial status is paid', () {
      final json = {
        'orders': [
          for (var i = 1; i <= 2; i++)
            {
              'id': 450789460 + i,
              'name': '#100$i',
              'created_at': '2026-11-10T10:00:00-05:00',
              'financial_status': 'paid',
              'total_price': '409.94',
              'shipping_address': {'first_name': 'Bob', 'last_name': 'Norman', 'address1': 'Chestnut Street 9$i', 'city': 'Louisville', 'phone': '+1(123)555-555$i'},
              'line_items': [
                {'title': 'IPod Nano', 'quantity': 1, 'price': '199.00', 'sku': 'IPOD2008PINK'},
              ],
            },
        ],
      };
      final f = findOrderLists(json).single;
      final o = f.orders().first;
      expect(o.number, '#1001');
      expect(o.name, 'Bob Norman');
      expect(o.paid, 409.94);
      expect(o.created, DateTime.utc(2026, 11, 10, 15));
      expect(o.lines.single.name, 'IPod Nano');
    });

    test('search results that wrap each order in "doc"', () {
      final json = {
        'mode': 'recent',
        'results': [
          for (var i = 1; i <= 3; i++) {'__kind': 'order', 'doc': mongoOrder(i, 'pending')},
        ],
      };
      final f = findOrderLists(jsonDecode(jsonEncode(json))).single;
      expect(f.path, 'results');
      expect(f.mapping.fields[OrderField.phone], 'doc.shipping.phone');
      expect(f.orders().first.number, 'VM-101');
    });

    test('product, customer and sales-by-day lists are not orders', () {
      final products = [
        for (var i = 1; i <= 3; i++)
          {
            '_id': 'p$i',
            'name': 'Toy $i',
            'price': 1190,
            'stock': 5,
            'sku': 'T-$i',
            'status': 'active',
            'images': ['https://cdn/x.jpg'],
            'variants': [
              {'name': 'Red', 'price': 1190, 'sku': 'T-$i-R'},
            ],
            'createdAt': '2026-11-01T00:00:00Z',
          },
      ];
      final customers = [
        for (var i = 1; i <= 3; i++)
          {'_id': 'c$i', 'name': 'Customer $i', 'phone': '0171200000$i', 'address': 'Mirpur', 'createdAt': '2026-11-01T00:00:00Z', 'totalOrders': i},
      ];
      final byDay = [
        for (var i = 1; i <= 3; i++) {'date': '2026-11-0$i', 'total': 15000 + i, 'orders': 12},
      ];
      expect(findOrderLists(products), isEmpty);
      expect(findOrderLists(customers), isEmpty);
      expect(findOrderLists(byDay), isEmpty);
      expect(findOrderLists({'token': 'abc', 'user': {'name': 'Admin'}}), isEmpty);
    });

    test('a table read from a page: headers as names, day-first dates, ৳ amounts', () {
      final rows = tableRows(
        ['SL', 'Invoice', 'Date', 'Customer', 'Phone', 'Amount', 'Status', 'Action'],
        [
          ['1', 'INV-1001', '10/11/2026', 'Rahim', '01711111111', '৳ 1,250', 'Pending', 'View Edit'],
          ['2', 'INV-1002', '09/11/2026', 'Karim', '01811111111', '৳ 980', 'Delivered', 'View Edit'],
        ],
      );
      final f = judgeRows(rows)!;
      expect(f.mapping.fields[OrderField.number], 'Invoice');
      expect(f.mapping.fields[OrderField.id], 'Invoice', reason: 'SL restarts on every page: never the id');
      final o = f.orders().first;
      expect(o.total, 1250);
      expect(o.created.toLocal().day, 10);
      expect(o.created.toLocal().month, 11);
      expect(f.orders()[1].status, 'Delivered');
    });

    test('pasted from a website (tabs) or a CSV file (quotes, commas)', () {
      final (h1, r1) = parsePastedTable('Invoice\tCustomer\tPhone\tTotal\n#A-1\tRahim\t01711111111\t1250\n#A-2\tKarim\t01811111111\t980\n');
      final o1 = judgeRows(tableRows(h1, r1))!.orders();
      expect(o1.map((o) => o.number), ['#A-1', '#A-2']);
      final (h2, r2) = parsePastedTable('Invoice,Customer,Phone,Address,Total\r\n'
          'A-1,"Rahim Uddin","01711111111","House 2, Road 4, Mirpur","1,250"\r\n'
          'A-2,Karim,01811111111,Agrabad,980\r\n');
      final o2 = judgeRows(tableRows(h2, r2))!.orders();
      expect(o2.first.address, 'House 2, Road 4, Mirpur');
      expect(o2.first.total, 1250);
    });

    test('a row with no order number still gets the same id every time', () {
      final rows = tableRows(['Customer', 'Phone', 'Date', 'Total'], [
        ['Rahim', '01711111111', '10/11/2026', '1250'],
      ]);
      final m = autoMap(rows);
      final a = m.toOrder(rows.first)!;
      final b = m.toOrder(Map<String, dynamic>.from(rows.first))!;
      expect(a.id, startsWith('row-'));
      expect(a.id, b.id);
    });
  });

  group('values', () {
    test('money', () {
      expect(parseMoney('৳ 1,250.00'), 1250);
      expect(parseMoney('Tk. 1250/-'), 1250);
      expect(parseMoney('১২৫০'), 1250);
      expect(parseMoney('BDT 99.5'), 99.5);
      expect(parseMoney(1620), 1620);
      expect(parseMoney({'amount': '70'}), 70);
      expect(parseMoney(true), isNull);
      expect(parseMoney('10/11/2026'), isNull);
      expect(parseMoney('Cash on delivery'), isNull);
    });

    test('dates', () {
      expect(parseWhen('2026-11-10T08:00:00.000Z'), DateTime.utc(2026, 11, 10, 8));
      expect(parseWhen(1762761600000), DateTime.fromMillisecondsSinceEpoch(1762761600000, isUtc: true));
      expect(parseWhen(1762761600), DateTime.fromMillisecondsSinceEpoch(1762761600000, isUtc: true));
      expect(parseWhen({r'$date': '2026-11-10T08:00:00Z'}), DateTime.utc(2026, 11, 10, 8));
      final d = parseWhen('10 Nov 2026, 3:42 PM')!.toLocal();
      expect([d.day, d.month, d.hour, d.minute], [10, 11, 15, 42]);
      final e = parseWhen('11/10/2026')!.toLocal();
      expect([e.day, e.month], [11, 10], reason: 'day first, as in Bangladesh');
      expect(parseWhen('VM-1001'), isNull);
    });

    test('a mapping survives being saved', () {
      final m = autoMap([mongoOrder(1, 'pending'), mongoOrder(2, 'pending')].map((o) => jsonDecode(jsonEncode(o)) as Map<String, dynamic>).toList());
      final back = OrderMapping.fromJson(jsonDecode(jsonEncode(m.toJson())) as Map<String, dynamic>);
      expect(back.fields, m.fields);
      expect(back.items, m.items);
      expect(back.itemFields, m.itemFields);
    });

    test('paging details', () {
      expect(pageInfo({'orders': [], 'hasNextPage': true}, 'orders').more, isTrue);
      expect(pageInfo({'data': [], 'next_page_url': null}, 'data').more, isFalse);
      expect(pageInfo({'data': {'docs': [], 'totalPages': 4}}, 'data.docs').lastPage, 4);
      expect(pageInfo({'items': [], 'meta': {'pagination': {}, 'last_page': 2}}, 'items').lastPage, 2);
    });
  });
}
