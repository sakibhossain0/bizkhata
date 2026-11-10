# Website orders: the BizKhata API

BizKhata can pull orders (and optionally products, prices and stock) from an online store every few
minutes. Two kinds of store are supported:

* **WooCommerce**: built in. Create a key under *WooCommerce → Settings → Advanced → REST API*
  with **Read** permission, then enter the site address, consumer key and consumer secret in
  *Settings → Website orders*.
* **Your own website**: add the two read-only endpoints below, then choose
  *My own website (BizKhata API)* and enter the API address and key.

## Endpoints

Both are `GET`, answer JSON, and require `Authorization: Bearer <API key>` (any long random string
you choose). Serve them over HTTPS only.

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
| `pending`, `processing`, `accepted`, `confirmed`, `hold`, anything else | waiting order |
| `shipped`, `dispatched`, `in_transit`, `booked` | handed to the courier (tracking code saved) |
| `delivered`, `completed`, `partial` | delivered, money collected |
| `returned` | returned, goods back in stock |
| `cancelled`, `canceled`, `failed`, `refunded` | cancelled, goods back in stock |
| `draft`, `incomplete`, `abandoned` | ignored |

New orders that are already cancelled or returned are not imported. Orders placed before the
"bring in orders placed from" date are ignored.

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

## Example: Express + Mongoose

Adjust the field names to your schema. This adds a read-only feed and touches nothing else.

```js
// routes/bizkhata.js
const express = require('express');
const Order = require('../models/Order');
const Product = require('../models/Product');

const router = express.Router();
const PAGE = 50;

router.use((req, res, next) => {
  const key = process.env.BIZKHATA_API_KEY;
  if (!key || req.get('Authorization') !== `Bearer ${key}`) return res.status(401).json({ error: 'unauthorized' });
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

module.exports = router;

// app.js:  app.use('/api/v1/bizkhata', require('./routes/bizkhata'));
// .env:    BIZKHATA_API_KEY=<a long random string>
```

Then in BizKhata: **API address** `https://api.yourshop.com/api/v1/bizkhata`, **API key** the same
string. Press **Test connection**, choose the start date, and save.

## Notes

* Make sure `updatedAt` changes whenever an order's status changes (Mongoose `timestamps: true`
  does this), or BizKhata won't see the change.
* With Google Drive sync on, only one device fetches website orders (the one where the connection
  was saved, changeable under *Settings → Website orders*), so no order is imported twice.
* The website keys are stored in the shop's data and travel with Google Drive sync and backups;
  use a read-only key.
