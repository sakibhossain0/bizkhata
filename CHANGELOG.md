# Changelog

## 1.2.1 (10 November 2026)

- Google sign-in and Google Drive sync are switched on in the downloads: Settings → *Google Drive
  & devices*, or *Open a shop from Google Drive* on the first screen.
- The privacy policy now says how to reach us.

## 1.2.0 (10 November 2026)

**New**
- **Google account and Google Drive sync.** Sign in with Google and keep a shop in your own Google
  Drive (a hidden folder only BizKhata can open). Open the same shop on other computers and phones
  and use them at the same time: each device works offline and catches up within a minute when
  online. Changes merge record by record, sales from every device come off the stock, every device
  has its own invoice letter, and product photos travel too. Needs the one-time Google Cloud setup
  in `docs/google-setup.md`.
- **Website orders.** Connect a WooCommerce store, or your own website through the simple BizKhata
  API (`docs/website-api.md`), and orders come in by themselves every few minutes as online orders.
  When the website marks an order shipped, delivered, returned or cancelled, BizKhata follows, with
  the money. Optionally brings in products and prices, and stock when the website is the master.
- Settings → *Google Drive & devices* and *Website orders*; a sync indicator in the sidebar;
  *Open a shop from Google Drive* on the first screen and in the business switcher; *Fetch now* on
  the Orders page.

**Fixed**
- Windows: `bizkhata.exe` started without the rest of its folder (for example, copied out of the
  portable zip on its own) now says in English and Bangla what to do, instead of Windows stopping
  with "printing_plugin.dll was not found".
- Windows: the app no longer needs the Microsoft Visual C++ Redistributable, so it starts on a
  freshly installed PC.
- The portable zip now holds one `BizKhata` folder with a short README, and
  `tool\release_windows.ps1` builds the installer and the zip in one step.

**Data**
- Database version 3 (website links, change tracking for sync). Existing shops upgrade
  automatically; tested from versions 1 and 2.

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
