import 'dart:convert';
import 'dart:io';

import 'package:bizkhata/ui/widgets/shop_mark.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// A 1x1 PNG.
const _png = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=';

void main() {
  testWidgets('the shop switcher shows the business logo, or the type icon without one', (t) async {
    final dir = Directory.systemTemp.createTempSync('bk_logo_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final logo = File('${dir.path}${Platform.pathSeparator}logo.png')..writeAsBytesSync(base64Decode(_png));

    await t.pumpWidget(MaterialApp(
      home: Column(children: [
        ShopMark(key: const ValueKey('a'), logo: logo.path, icon: '🛒'),
        const ShopMark(key: ValueKey('b'), icon: '🛒'),
        ShopMark(key: const ValueKey('c'), logo: '${dir.path}${Platform.pathSeparator}gone.png', icon: '🛒'),
        const ShopMark(key: ValueKey('d'), logo: '', icon: '🛒'),
      ]),
    ));

    Finder inside(String key, String mark) => find.descendant(of: find.byKey(ValueKey(key)), matching: find.byKey(ValueKey(mark)));
    expect(inside('a', 'shop-mark-logo'), findsOneWidget);
    expect((t.widget<Image>(find.byType(Image)).image as FileImage).file.path, logo.path);
    // No logo, a logo file that isn't on this device, an empty setting: the cart.
    for (final k in ['b', 'c', 'd']) {
      expect(inside(k, 'shop-mark-icon'), findsOneWidget, reason: k);
    }
    expect(find.text('🛒'), findsNWidgets(3));
  });
}
