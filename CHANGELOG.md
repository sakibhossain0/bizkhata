# Changelog

## 1.4.0 (11 November 2026)

**New**
- **Orders from any website, with nothing changed on the website.** Settings → Website orders →
  *Any website (sign in)* opens a built-in browser. Sign in to your website's admin panel as usual
  and open the page that lists your orders. BizKhata spots the order list the page loads, shows the
  first orders with the columns it matched (tap a column title to fix one), and then keeps checking
  for new orders in the background for as long as the website keeps you signed in. Orders come in as
  online orders and follow the website's status (shipped, delivered, returned, cancelled), so sales,
  delivery charges and profit sit next to your expenses. It only reads: nothing is sent to the website.
  It works with admin panels that load their orders from their own server (most modern ones, whatever
  they are built with) and with plain table pages. If the orders page has tabs (pending, shipped …),
  BizKhata asks for all statuses at once when the website allows it, or you add each tab.
- **Paste orders.** Copy the orders table from any website (or Excel) and paste it into BizKhata to
  bring those orders in once. Pasting the same table again brings nothing twice.

**Changed**
- The shop switcher at the top left shows the logo set in Settings → Business profile. Without a
  logo it shows the business type's icon, as before.

**Privacy**
- Your website password is typed into the website's own page; BizKhata never reads or keeps it. The
  built-in browser keeps its sign-in on this device, in a separate folder for each shop that backups
  and Google Drive never include.

**Windows**
- The built-in browser uses Microsoft Edge WebView2, which comes with Windows 11 and up-to-date
  Windows 10. If it's missing, BizKhata says so and links to Microsoft's download.

## 1.3.0 (11 November 2026)

**New**
- **Website orders work both ways.** With your own website (BizKhata API), confirming an order,
  booking a courier or handing it over, marking it delivered, returned or cancelled in BizKhata is
  sent back to the website a few seconds later, or as soon as the internet is back. Orders accepted
  on the website arrive confirmed. Each website order shows whether the website has the same status,
  or why it refused a change. WooCommerce stays read-only.
- **The API address is enough.** The API key is now optional: a website can give BizKhata one link
  with a secret in it, from its admin panel, so nobody has to set anything up on the hosting.
  `docs/website-api.md` has the new status link and an example.
- **Google account first.** BizKhata opens with *Continue with Google*; the first sign-in is the
  sign-up. Each shop belongs to the account that made it (shops from before are kept for the first
  account that signs in on that device), and another account on the same PC doesn't see them.
- **Log out** in Settings → *Account · Log out* and in the shop menu at the top left. The shops stay
  on the device and in Google Drive for the next sign-in.

**Changed**
- The first screen no longer offers *Explore with sample data*.

**Fixed**
- Windows: the title bar showed "BizKhata" on a black box and the minimize, maximize and close
  buttons faded out and did not respond. The window now has the normal Windows title bar.

**Data**
- Database version 4 (each website order remembers the website's last known status). Existing shops
  upgrade automatically; tested from versions 1, 2 and 3. Devices that share a shop through Google
  Drive should all be updated to 1.3.0.

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
