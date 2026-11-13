import '../core/format.dart';
import '../couriers/registry.dart';
import '../core/i18n.dart';
import '../data/biz.dart';
import 'messaging.dart';

/// The messages a shop sends its customers. Each has a default in both
/// languages; the owner can rewrite them in Settings.
enum MsgKind { invoice, due, confirmed, shipped, delivered }

const _defaults = {
  MsgKind.invoice: (
    'Dear {name}, thank you for shopping at {shop}.\nInvoice {invoice}\n{items}\nTotal {total} · Paid {paid} · Due {due}\n{payment}',
    'প্রিয় {name}, {shop}-এ কেনাকাটার জন্য ধন্যবাদ।\nইনভয়েস {invoice}\n{items}\nমোট {total} · পরিশোধ {paid} · বাকি {due}\n{payment}',
  ),
  MsgKind.due: (
    'Dear {name}, your due at {shop} is {amount}. Please pay at your convenience. Thank you.\n{payment}',
    'প্রিয় {name}, {shop}-এ আপনার বাকি {amount}। সুবিধামতো পরিশোধ করুন। ধন্যবাদ।\n{payment}',
  ),
  MsgKind.confirmed: (
    'Hello {name}, your order {invoice} ({total}) at {shop} is confirmed. Cash on delivery: {cod}.',
    'আসসালামু আলাইকুম {name}, {shop}-এ আপনার অর্ডার {invoice} ({total}) কনফার্ম হয়েছে। ক্যাশ অন ডেলিভারি: {cod}।',
  ),
  MsgKind.shipped: (
    'Hello {name}, your order {invoice} from {shop} is on the way with {courier}. Tracking: {tracking}',
    'আসসালামু আলাইকুম {name}, {shop}-এর অর্ডার {invoice} {courier}-এ পাঠানো হয়েছে। ট্র্যাকিং: {tracking}',
  ),
  MsgKind.delivered: (
    'Thank you {name}! Your order {invoice} was delivered. We hope to see you again at {shop}.',
    'ধন্যবাদ {name}! আপনার অর্ডার {invoice} ডেলিভারি হয়েছে। আবার {shop}-এ আসবেন।',
  ),
};

/// Tags each message understands, shown under the editor.
const templateTags = {
  MsgKind.invoice: ['{name}', '{shop}', '{invoice}', '{items}', '{total}', '{paid}', '{due}', '{payment}'],
  MsgKind.due: ['{name}', '{shop}', '{amount}', '{payment}'],
  MsgKind.confirmed: ['{name}', '{shop}', '{invoice}', '{total}', '{cod}', '{payment}'],
  MsgKind.shipped: ['{name}', '{shop}', '{invoice}', '{courier}', '{tracking}', '{cod}'],
  MsgKind.delivered: ['{name}', '{shop}', '{invoice}'],
};

String defaultTemplate(MsgKind k) => isBangla ? _defaults[k]!.$2 : _defaults[k]!.$1;

String templateText(Map<String, String> settings, MsgKind k) {
  final custom = settings.json(K.templates)[k.name];
  return custom is String && custom.trim().isNotEmpty ? custom : defaultTemplate(k);
}

/// Fills `{tags}` and drops lines that end up empty (e.g. no payment numbers set).
String fillTemplate(String template, Map<String, String> values) {
  var out = template;
  values.forEach((k, v) => out = out.replaceAll('{$k}', v));
  final lines = out.split('\n').map((l) => l.trimRight()).where((l) => l.trim().isNotEmpty);
  return lines.join('\n').trim();
}

/// "{payment}": the shop's bKash/Nagad numbers, one per line.
String paymentLine(Map<String, String> settings) {
  final nums = settings.str(K.paymentNumbers).trim();
  if (nums.isEmpty) return '';
  return isBangla ? 'পেমেন্ট: $nums' : 'Pay to: $nums';
}

/// Invoice/receipt message for a sale.
String invoiceMessage(Map<String, String> settings, SaleDetail d) {
  final s = d.sale;
  final items = [
    for (final it in d.items)
      if (s.status == 'returned' || it.netQty > 0)
        '• ${it.name} × ${qty(s.status == 'returned' ? it.qty : it.netQty)} = ${money(s.status == 'returned' ? it.total : it.netTotal)}',
  ].join('\n');
  final text = fillTemplate(templateText(settings, MsgKind.invoice), {
    'name': d.contact?.name ?? s.shipName ?? T.walkIn.s,
    'shop': settings.str(K.businessName),
    'invoice': s.invoiceNo,
    'items': items,
    'total': money(s.total),
    'paid': money(s.paid),
    'due': money(d.due > 0 ? d.due : 0),
    'payment': paymentLine(settings),
  });
  return withDeliveryLine(text, s.deliveryCharge);
}

/// The invoice message lists only the items, so without this the delivery
/// charge would be missing from the sum. It goes right after the last item,
/// or at the end when the shop's own message has no item list.
String withDeliveryLine(String text, double delivery) {
  if (delivery <= 0) return text;
  final rows = text.split('\n');
  final lastItem = rows.lastIndexWhere((r) => r.startsWith('• '));
  if (lastItem < 0) return '$text\n${T.deliveryCharge.s}: ${money(delivery)}';
  rows.insert(lastItem + 1, '• ${T.deliveryCharge.s} = ${money(delivery)}');
  return rows.join('\n');
}

String dueMessage(Map<String, String> settings, String name, double amount) =>
    fillTemplate(templateText(settings, MsgKind.due), {
      'name': name,
      'shop': settings.str(K.businessName),
      'amount': money(amount),
      'payment': paymentLine(settings),
    });

/// Order status message (confirmed / shipped / delivered).
String orderMessage(Map<String, String> settings, MsgKind kind, SaleDetail d) {
  final s = d.sale;
  final ship = d.shipment;
  return fillTemplate(templateText(settings, kind), {
    'name': s.shipName ?? d.contact?.name ?? '',
    'shop': settings.str(K.businessName),
    'invoice': s.invoiceNo,
    'total': money(s.total),
    'cod': money(d.due > 0 ? d.due : 0),
    'courier': ship == null ? '' : (courierNames[ship.courier] ?? ship.courier),
    'tracking': ship?.trackingUrl ?? ship?.trackingCode ?? ship?.consignmentId ?? '',
    'payment': paymentLine(settings),
  });
}

/// Sends the order message by SMS when "auto SMS" is on and a gateway is set.
/// Never throws: a failed text must not undo a booking or delivery.
Future<bool> autoNotifyOrder(Biz biz, int saleId, MsgKind kind) async {
  try {
    final settings = await biz.settings.all();
    if (!settings.flag(K.autoSms)) return false;
    final d = await biz.sales.detail(saleId);
    final phone = d?.sale.shipPhone ?? d?.contact?.phone;
    if (d == null || phone == null || phone.isEmpty) return false;
    await Messaging.sms(biz, phone, orderMessage(settings, kind, d));
    return true;
  } catch (_) {
    return false;
  }
}
