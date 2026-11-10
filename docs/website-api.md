# Website orders: the BizKhata API

BizKhata brings in orders (and optionally products, prices and stock) from an online store every few
minutes. Two kinds of store are supported:

* **WooCommerce**: built in, read-only. Create a key under *WooCommerce → Settings → Advanced →
  REST API* with **Read** permission, then enter the site address, consumer key and consumer secret
  in *Settings → Website orders*.
* **Your own website**: add the endpoints below, then choose *My own website (BizKhata API)* and
  paste the API address. Status changes made in BizKhata (confirm, courier, delivered, returned,
  cancelled) are sent back to the website.

## The address is the key

The shop owner should never have to open their hosting to set this up. The simplest safe way is an
address with a long random secret in it, made by the website and shown in its admin panel:

```
https://api.yourshop.com/api/bizkhata/k7Qm2xV9pL4tR8wZ3nB6yD1sF5hJ0cGa
```

The owner copies that one link into BizKhata and leaves the API key empty. The website keeps the
secret in its database, and a *New link* button in its admin panel makes the old link stop working.

Without a secret in the address, anyone who guesses it can read every customer's name, phone and
address, so don't serve these endpoints at a plain, guessable address.

If you prefer a separate key instead, BizKhata sends it as `Authorization: Bearer <key>` when the
owner fills in the optional *API key* box. A `?key=` already in the address is kept too.

Serve everything over HTTPS only.

## Endpoints

All answer JSON. BizKhata adds the paths below to the API address.

### `GET <api>/orders?since=<ISO time>&page=<n>`

Orders **changed** after `since` (created, edited or status changed), **oldest change first**, about
50 per page. `since` is missing on the very first call.

```json
{
  "orders": [
    {
      "id": "65ab3f...",
      "number": "INV-1043",
      "status": "pending",
      "created_at": "2026-11-09T09:00:00+06:00",
      "updated_at": "2026-11-09T09:30:00+06:00",
      "customer": {
        "name": "Karim",
        "phone": "01811000002",
        "address": "House 3, Road 14, Dhanmondi",
        "area": "Dhanmondi",
        "city": "Dhaka"
      },
      "items": [
        { "product_id": "64f1...", "sku": "TSHIRT-L", "name": "T-shirt (L)", "qty": 2, "price": 450 }
      ],
      "shipping": 120,
      "discount": 0,
      "total": 1020,
      "paid": 0,
      "payment_method": "cod",
      "courier": "Steadfast",
      "tracking_code": "SF123456",
      "note": "Call before coming"
    }
  ],
  "next_page": 2
}
```

* `price` is the **selling price of one unit** before the order discount. If your products store a
  regular price and a discount amount, send `price - discount`.
* `paid` is money already received online (bKash, card, advance); cash on delivery is `0`.
* `total` should equal `sum(qty × price) - discount + shipping`; if it doesn't (fees, rounding),
  BizKhata adds the difference as "Other charges" so its total matches yours exactly.
* `next_page` is `null` on the last page.

**Status** decides what BizKhata does (names are case-insensitive):

| Your status | In BizKhata |
|---|---|
| `pending`, `hold`, `processing`, anything not listed | waiting order |
| `accepted`, `confirmed`, `in_review` | confirmed order |
| `shipped`, `dispatched`, `in_transit`, `booked` | handed to the courier (tracking code saved) |
| `delivered`, `completed`, `partial` | delivered, money collected |
| `returned` | returned, goods back in stock |
| `cancelled`, `canceled`, `failed`, `refunded` | cancelled, goods back in stock |
| `draft`, `incomplete`, `abandoned` | ignored |

New orders that are already cancelled or returned are not imported. Orders placed before the
"bring in orders placed from" date are ignored. BizKhata only moves an order forward to match the
website, never back.

### `GET <api>/products?since=<ISO time>&page=<n>`

```json
{
  "products": [
    { "id": "64f1...", "sku": "TSHIRT-L", "name": "T-shirt (L)", "price": 450, "stock": 37, "updated_at": "2026-11-09T08:00:00Z" }
  ],
  "next_page": null
}
```

Products are matched by `id` (once linked), then `sku`, then exact name. `stock` is only copied
when the owner turns on *Stock comes from the website*.

Alternative field names are accepted where common (`_id`, `invoice`, `quantity`, `delivery_charge`,
`advance`, `createdAt`/`updatedAt` …), and a plain JSON array instead of `{ "orders": [...] }` works
too.

### `POST <api>/orders/<id>/status`

When an order that came from the website moves along in BizKhata, BizKhata tells the website, a few
seconds later (or as soon as it is back online):

```json
{ "status": "shipped", "courier": "pathao", "tracking_code": "PT-77", "consignment_id": "PT-77", "source": "bizkhata" }
```

| Done in BizKhata | `status` sent |
|---|---|
| Confirm order | `accepted` |
| Book a courier / handed over | `shipped` (with `courier`, `tracking_code`, `consignment_id` when booked in BizKhata) |
| Mark delivered | `delivered`, or `partial` if less was collected |
| Mark returned | `returned` |
| Cancel order | `cancelled` |

* If your system needs steps in between (for example `pending → accepted → shipped`), take them.
* Answer `200` with the order's status afterwards: `{ "ok": true, "status": "shipped" }`.
* If the move isn't allowed, answer `400`/`409`/`422` with a message and the current status:
  `{ "message": "Cannot move an order from \"shipped\" to \"cancelled\"", "status": "shipped" }`.
  BizKhata shows the message on the order and doesn't try again until the order changes in
  BizKhata again.
* A `5xx` or no answer is retried later. A `404` (no such order, or no status endpoint at all) is
  treated as a refusal, so websites without this endpoint still work read-only.

## Example: Express + Mongoose

Adjust the field names to your schema. The secret lives in the database, so nothing is set on the
server by hand.

```js
// routes/bizkhata.js
const crypto = require('crypto');
const express = require('express');
const Order = require('../models/Order');
const Product = require('../models/Product');
const Setting = require('../models/Setting'); // { key: String (unique), value: Mixed }

const PAGE = 50;
const router = express.Router({ mergeParams: true });

async function currentToken() {
  const s = await Setting.findOne({ key: 'bizkhata' }).lean();
  return s?.value?.token || '';
}

// The secret in the address is the key. Wrong or missing: same 404 as any unknown page.
router.use(async (req, res, next) => {
  const expected = await currentToken();
  const a = Buffer.from(String(req.params.token || ''));
  const b = Buffer.from(expected);
  if (!expected || a.length !== b.length || !crypto.timingSafeEqual(a, b)) return res.status(404).json({ message: 'Not found' });
  next();
});

function window(req) {
  const since = req.query.since ? new Date(req.query.since) : new Date(0);
  const page = Math.max(1, parseInt(req.query.page, 10) || 1);
  return { since, page, skip: (page - 1) * PAGE };
}

router.get('/orders', async (req, res) => {
  const { since, page, skip } = window(req);
  const docs = await Order.find({ updatedAt: { $gt: since } })
    .sort({ updatedAt: 1, _id: 1 }).skip(skip).limit(PAGE + 1).lean();
  res.json({
    orders: docs.slice(0, PAGE).map((o) => ({
      id: String(o._id),
      number: o.invoiceNo,
      status: o.status,
      created_at: o.createdAt,
      updated_at: o.updatedAt,
      customer: { name: o.name, phone: o.phone, address: o.address, area: o.area, city: o.city },
      items: (o.items || []).map((i) => ({
        product_id: String(i.product), sku: i.sku, name: i.name, qty: i.quantity, price: i.price,
      })),
      shipping: o.deliveryCharge || 0,
      discount: o.discount || 0,
      total: o.total,
      paid: o.paidAmount || 0,
      payment_method: o.paymentMethod,
      courier: o.courier,
      tracking_code: o.trackingCode,
      note: o.note,
    })),
    next_page: docs.length > PAGE ? page + 1 : null,
  });
});

router.get('/products', async (req, res) => {
  const { since, page, skip } = window(req);
  const docs = await Product.find({ updatedAt: { $gt: since } })
    .sort({ updatedAt: 1, _id: 1 }).skip(skip).limit(PAGE + 1).lean();
  res.json({
    products: docs.slice(0, PAGE).map((p) => ({
      id: String(p._id), sku: p.sku, name: p.name,
      price: (p.price || 0) - (p.discount || 0), // selling price
      stock: p.stock, updated_at: p.updatedAt,
    })),
    next_page: docs.length > PAGE ? page + 1 : null,
  });
});

// Which statuses may follow which. Use your own rules here.
const NEXT = {
  pending: ['accepted', 'cancelled'],
  accepted: ['shipped', 'cancelled'],
  shipped: ['delivered', 'partial', 'returned'],
};

router.post('/orders/:id/status', async (req, res) => {
  const order = await Order.findById(req.params.id);
  if (!order) return res.status(404).json({ message: 'Order not found' });
  const target = String(req.body.status || '').toLowerCase();
  // Walk pending -> accepted -> shipped ... until the target is reached.
  const steps = [];
  for (let at = order.status; at !== target; ) {
    const next = (NEXT[at] || []).find((s) => s === target) || (NEXT[at] || [])[0];
    if (!next || (next === 'cancelled' && target !== 'cancelled') || steps.length > 5) {
      return res.status(409).json({ message: `Cannot move an order from "${order.status}" to "${target}"`, status: order.status });
    }
    steps.push(next);
    at = next;
  }
  order.status = target;
  if (req.body.tracking_code) order.trackingCode = req.body.tracking_code;
  await order.save();
  res.json({ ok: true, status: order.status });
});

module.exports = router;

// app.js:  app.use('/api/bizkhata/:token', require('./routes/bizkhata'));
//
// Admin panel, behind your admin login: make (or replace) the link and show it.
//   const token = crypto.randomBytes(24).toString('base64url');
//   await Setting.findOneAndUpdate({ key: 'bizkhata' }, { value: { token } }, { upsert: true });
//   res.json({ link: `https://${req.get('host')}/api/bizkhata/${token}` });
```

Then in BizKhata: paste the link from the admin panel as the **API address**, leave the key empty,
press **Test connection**, choose the start date, and save.

## Notes

* Make sure `updatedAt` changes whenever an order's status changes (Mongoose `timestamps: true`
  does this), or BizKhata won't see the change.
* With Google Drive sync on, only one device fetches website orders and sends status changes (the
  one where the connection was saved, changeable under *Settings → Website orders*), so nothing is
  imported or sent twice. Changes made on the other devices reach it through Google Drive.
* The website link and keys are stored in the shop's data and travel with Google Drive sync and
  backups. If one leaks, make a new link in the website's admin panel.
