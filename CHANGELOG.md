# Changelog

## 1.1.0 (29 October 2026)

**Fixed**
- Adding a product with stock: the stock box now sits next to the prices (visible without scrolling
  on a 1280×680 screen), and a number typed into "Unit" is refused instead of silently becoming the unit.
- Window no longer opens bigger than the screen: it fits the monitor's work area, opens maximised the
  first time and remembers its size and position.
- Deleting a business moves it to *Recently deleted* (30 days, restorable) instead of risking a
  half-deleted folder; leftovers from older versions are tidied at start-up.
- POS product cards: big prices shrink instead of wrapping.
- Couriers, checked against the official API guides: Steadfast invoice numbers are cleaned to the
  allowed characters and the official tracking link is used; Pathao no longer fails when the area
  can't be matched (it fills city/zone from the address) and keeps weight within 0.5–10 kg; RedX
  parcels that move on to "paid" are settled as delivered.

**New**
- Staff accounts: owner PIN plus a PIN per staff member, Manager and Cashier roles, who-did-what on
  every sale, payment and expense, sales-by-staff report, auto-lock after idle minutes, pause after
  five wrong PINs.
- Partial returns: take back any quantity of any line; discount and VAT are split fairly, stock goes
  back, and the refund comes off the due first.
- Share receipts as a picture, PDF, WhatsApp or SMS text; WhatsApp button on the "sale done" screen.
- One-click printing to a chosen receipt printer (Settings → Invoice · Printer), with a test print.
- Day-end summary (dashboard, cashbox, reports): sales, money in and out by source, every account's
  opening → closing; printable on the receipt printer.
- Message templates with `{tags}` and your bKash/Nagad numbers for receipts, due reminders and order
  updates; optional automatic SMS when an order is confirmed, sent to the courier or delivered.
- `Ctrl+K` search across products, customers, suppliers, invoices and orders (search icon on phones).
- Customers and suppliers: import and export with Excel (CSV).
- Share backup to Google Drive, email or another phone.
- Android release signing for Google Play, store listing text and privacy policy (`docs/`).

**Data**
- Database version 2 (staff, `created_by`, returned quantities). Existing shops upgrade automatically
  on first open; tested from a version 1 database.

## 1.0.0 (2 October 2026)

First release: POS, khata, stock, purchases, online orders with Steadfast/Pathao/RedX, expenses,
cashbox, reports, Bangla/English, Windows installer and Android APKs.
