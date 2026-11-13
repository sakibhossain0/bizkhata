# BizKhata (বিজখাতা)

Stock, baki khata, counter sales and courier booking for small shops in Bangladesh. It runs on Windows and Android, in Bangla or English, and works without internet. You sign in with your Google account; your data stays on your own devices and, if you choose, in your own Google Drive. There is no BizKhata server.

বাংলায়: দোকানের স্টক, বাকির খাতা, বিক্রি আর কুরিয়ার বুকিং এক অ্যাপে। উইন্ডোজ ও অ্যান্ড্রয়েডে চলে, বাংলা ও ইংরেজি দুই ভাষাতেই, ইন্টারনেট ছাড়াও। গুগল অ্যাকাউন্ট দিয়ে সাইন ইন করুন; সব তথ্য আপনার নিজের ডিভাইসে, আর চাইলে নিজের গুগল ড্রাইভে থাকে।

**Version 1.4.1** · [Changelog](CHANGELOG.md) · [Privacy policy](docs/privacy-policy.md)

![Dashboard with today's sales, khata totals and recent invoices](docs/screenshots/dashboard.png)

## Screenshots

<table>
  <tr>
    <td width="50%"><img src="docs/screenshots/new-sale.png" alt="New sale screen"><br><sub>Counter sale with barcode search, cart and payment</sub></td>
    <td width="50%"><img src="docs/screenshots/khata-bangla.png" alt="Customer khata in Bangla"><br><sub>Customer khata with running balance, in Bangla</sub></td>
  </tr>
  <tr>
    <td><img src="docs/screenshots/online-order.png" alt="Online order with courier details"><br><sub>Online order with courier tracking and delivery record</sub></td>
    <td><img src="docs/screenshots/reports.png" alt="Reports screen"><br><sub>Reports, with Excel (CSV) export</sub></td>
  </tr>
  <tr>
    <td><img src="docs/screenshots/day-end.png" alt="Day-end summary dialog"><br><sub>Day-end summary, ready to print before closing</sub></td>
    <td><img src="docs/screenshots/partial-return.png" alt="Return items dialog"><br><sub>Partial return with a refund preview</sub></td>
  </tr>
  <tr>
    <td><img src="docs/screenshots/search.png" alt="Global search dialog"><br><sub>Ctrl+K search across products, customers and invoices</sub></td>
    <td><img src="docs/screenshots/staff.png" alt="Security and staff settings"><br><sub>Staff accounts, PINs and auto-lock</sub></td>
  </tr>
</table>

On a phone:

<table>
  <tr>
    <td><img src="docs/screenshots/phone-dashboard.png" alt="Phone dashboard in Bangla" width="190"></td>
    <td><img src="docs/screenshots/phone-sale.png" alt="Phone new sale screen" width="190"></td>
    <td><img src="docs/screenshots/phone-cart.png" alt="Phone cart" width="190"></td>
    <td><img src="docs/screenshots/phone-khata.png" alt="Phone khata in Bangla" width="190"></td>
  </tr>
</table>

The images are rendered from the built-in demo data by `test/shots_test.dart`, so all names and numbers in them are made up.

## Features

| Area | What it does |
|---|---|
| **New sale** (`F2`) | Barcode scanner or camera scan, product grid by category, custom items, wholesale prices, discount, VAT and an optional delivery charge, Cash / bKash / Nagad / Bank or **Due**, change calculation. Type the customer's name and phone right in the cart (optional; a known number links the customer). Anything unpaid goes to the customer's khata. |
| **Sales and returns** | Invoice list, printing on 58 mm, 80 mm or A4, one-click printing to a saved printer, sharing as a picture, PDF, WhatsApp or SMS. Partial returns split the discount and VAT by value, put the stock back and take the refund off the due first. |
| **Khata** (`F4`) | Customers and suppliers with দিলাম / পেলাম entries, running balance, পাবো / দেবো totals, WhatsApp and SMS due reminders, printable statements, CSV import and export. |
| **Products and stock** (`F3`) | Categories, units, SKU, barcodes (generate EAN-13 or scan), photos, cost / sale / wholesale prices, weighted-average cost, low-stock alerts, stock history, stock counts, label printing, CSV import and export. |
| **Purchases** (`F6`) | Stock in from suppliers, updates the average cost, unpaid part goes to the supplier's khata, cancel with full reversal. |
| **Online orders** (`F5`) | Phone lookup with the customer's delivery record, booking with Steadfast, Pathao or RedX (one by one or in bulk), status sync, automatic COD settlement, partial delivery, returns, optional automatic SMS. |
| **Money** (`F7`, `F8`) | Expenses by category, any number of money accounts, cash in and out, transfers, full history. |
| **Reports** (`F10`) | Sales, profit and loss, top products, stock value, dues, expenses, cash book and sales by staff, exportable to CSV. Day-end summary on screen or on the receipt printer. |
| **Staff** | Owner PIN plus a PIN for each employee, Manager and Cashier roles, who-did-what on every record, auto-lock when idle. |
| **Google account** | Sign in (or sign up) with Google before anything else. Each shop belongs to the account that made it, so on a shared PC another account doesn't see it. Log out from Settings or the shop menu. |
| **Google Drive sync** | While you are signed in, your shops are kept in your own Drive by themselves, and a new device lists them right after sign-in. Use a shop on several PCs and phones at once; each works offline and catches up within a minute. Records merge one by one, stock adds up sales from every device, and each device has its own invoice letter. Setup: [docs/google-setup.md](docs/google-setup.md). |
| **Website orders** | Orders from a WooCommerce store, or from your own site through the [BizKhata API](docs/website-api.md), arrive by themselves every few minutes. Accepted, shipped, delivered, returned and cancelled on the website are followed here, with the money; products, prices and (optionally) stock come along. With your own site it works both ways: confirm, courier, delivered, returned and cancelled in BizKhata go back to the website. One API address is enough (the key is optional). **Any other website, with nothing changed on it:** sign in to its admin panel in BizKhata's built-in browser and open the orders page; BizKhata recognises the order list the page loads and keeps checking for new orders (read-only). Or paste an orders table copied from any page. |
| **Everything else** | Several businesses in one app, daily automatic backups, sharing a backup to another device, `Ctrl+K` search, message templates with your bKash/Nagad numbers. Receipts are rendered as images so Bangla conjuncts come out correctly. |

## Download and install

Ready-made builds are on the [Releases page](https://github.com/sakibhossain0/bizkhata/releases).

**Windows 10 or 11.** Download `BizKhata-Setup-<version>.exe` and run it. It installs for your Windows user, so it doesn't need admin rights, and adds Start menu and desktop icons. Because the installer isn't code-signed, Windows may show "Windows protected your PC": click **More info**, then **Run anyway**.

The portable zip has the same app in a `BizKhata` folder, for a USB stick. Extract the whole zip, then open `bizkhata.exe` inside that folder. `bizkhata.exe` doesn't run on its own: keep it with the `data` folder and the `.dll` files, and use a shortcut to put it on the desktop.

**Android.** Download `BizKhata-<version>-android-arm64.apk` (`armv7` for older phones), open it, and allow installing apps from that source.

On Windows the shop's data lives in `%APPDATA%\BizKhata`, so updating or uninstalling the app keeps it.

When the app opens, pick a language and press **Continue with Google** (the first sign-in creates your account). Then set up your business, or open one you keep in Google Drive. To try the courier flow without real API keys, turn on **Test mode** under Settings → Online orders & couriers.

## Building from source

You need:

- [Flutter](https://docs.flutter.dev/get-started/install) 3.47 or newer
- For Windows: Visual Studio with the **Desktop development with C++** workload, and Developer Mode turned on
- For Android: the Android SDK

```bash
git clone https://github.com/sakibhossain0/bizkhata.git
cd bizkhata
flutter pub get
flutter run -d windows
```

Google sign-in needs your own OAuth client ids: copy `google_oauth.example.json` to
`google_oauth.json`, fill it in (see [docs/google-setup.md](docs/google-setup.md)), and add
`--dart-define-from-file=google_oauth.json` to `flutter run` and every `flutter build`. Without it
the app runs without accounts (handy for development), and Google sign-in is hidden. Release
builds always include it.

## Keyboard shortcuts

| Key | Action | Key | Action |
|---|---|---|---|
| `F2` | New sale | `F8` | Cashbox |
| `F3` | Products | `F9` or `Ctrl+Enter` | Complete the sale |
| `F4` | Customers | `F10` | Reports |
| `F5` | Online orders | `F12` | Select customer (in New sale) |
| `F6` | Purchases | `Ctrl+K` | Search everything |
| `F7` | Expenses | `Ctrl+N` | Add product (on the Products page) |
| `Ctrl+L` | Lock or switch user | `Ctrl+Home` | Home page |

## Staff roles

Set an owner PIN first, then add staff under Settings → Security · Staff. The lock screen then asks who is using the app.

| | Owner | Manager | Cashier |
|---|:---:|:---:|:---:|
| Sell, view stock, customers, online orders | ✓ | ✓ | ✓ |
| Collect dues and write khata entries | ✓ | ✓ | ✓ |
| See cost prices and profit | ✓ | ✓ | |
| Edit products and stock | ✓ | ✓ | |
| Returns and cancellations | ✓ | ✓ | |
| Delete khata entries, archive contacts | ✓ | ✓ | |
| Dashboard, purchases, suppliers, expenses, cashbox, reports | ✓ | ✓ | |
| Shop, invoice, courier and SMS settings | ✓ | ✓ | |
| Owner PIN, staff, backup and restore, deleting or switching business | ✓ | | |

## Couriers and SMS

| Courier | What you need | What works |
|---|---|---|
| Steadfast | API key and secret key | Booking, status sync, customer delivery record |
| Pathao | Client ID and secret, merchant email and password | Booking, status sync |
| RedX | API token | Booking, status sync |

Enter the keys under Settings → Online orders & couriers, then press **Test connection**. The adapters in `lib/couriers/` were checked against each courier's official API guide in October 2026.

SMS works with any provider that has an HTTP link. Paste the URL under Settings → SMS gateway with `{number}` and `{message}` where the values go.

## Data, backups and security

- Each business is one SQLite file. On Windows it is in `%APPDATA%\BizKhata\BizKhata\businesses\<id>\`, and on Android in the app's private storage.
- A backup is made automatically the first time you open a business each day, and the last 15 are kept. On Windows they go to `Documents\BizKhata Backups`, or to any folder you choose, such as a Google Drive folder. On a phone they stay inside the app, so use **Backup now** or **Share backup** to get a copy out.
- A deleted business stays under *Recently deleted* for 30 days and can be restored.
- With Google Drive sync on, the shop also lives in a hidden BizKhata folder in your Google Drive (only this app can open it): a weekly full copy plus small change files, and the product photos.
- **The database and backup files are not encrypted.** They hold your customer list and your courier and website API keys, so keep backups private. The PIN lock keeps people out of the app, not out of the file.
- Set the `BIZKHATA_DATA_DIR` environment variable to run a copy of the app on separate test data.

## How the numbers add up

- A contact's balance is the sum of their ledger entries. Above zero they owe you (পাবো), below zero you owe them (দেবো).
- Every taka entering or leaving an account is a cash transaction. An account's balance is its opening amount plus money in minus money out.
- Sales, purchases, returns and courier settlements write their stock moves, ledger entries and cash transactions in one database transaction.
- Revenue counts counter sales plus delivered online orders. Profit is net sales plus delivery charges minus the cost of goods, using weighted-average cost.
- A partial return reduces the sale itself. A full return keeps the original figures and marks the sale as returned, and reports leave it out.

## Project layout

```text
lib/
├── main.dart, app.dart      start-up, routes, boot / onboarding / lock phases
├── core/                    translations (English + Bangla), theme, formatting, window sizing
├── couriers/                Steadfast, Pathao and RedX adapters, plus a test-mode mock
├── sync/                    Google sign-in, Google Drive store, change tracking and merging
├── web/                     website connectors (WooCommerce, BizKhata API, any website via the built-in browser), order recognition, the importer
├── data/
│   ├── database.dart        tables and migrations
│   ├── business_store.dart  one database per business, backup, restore, recently deleted
│   └── repos/               sales, products, contacts, cash, orders, purchases, expenses, reports, staff, settings
├── services/                printing, WhatsApp and SMS, message templates
├── state/                   app state (session, lock, language)
└── ui/                      shell, screens, shared widgets
test/                        automated tests
drift_schemas/               database snapshots for the migration test
installer/                   Inno Setup script for the Windows installer, README for the portable zip
tool/release_windows.ps1     builds the Windows installer and portable zip
windows/runner/main.cpp      Windows start-up, including the check for missing files
docs/                        privacy policy, Play Store listing, Google and website API guides, screenshots
```

Built with Flutter, [drift](https://drift.simonbinder.eu/) (SQLite), [Riverpod](https://riverpod.dev/), [go_router](https://pub.dev/packages/go_router) and the [printing](https://pub.dev/packages/printing) and [pdf](https://pub.dev/packages/pdf) packages.

## Tests

```bash
flutter analyze
flutter test
```

| File | What it checks |
|---|---|
| `test/core_test.dart` | Invoices, stock, khata, cash and courier settlement add up |
| `test/v11_test.dart` | Partial-return maths, staff PINs and roles, courier rules |
| `test/migration_test.dart` | A version 1 database upgrades without losing data |
| `test/bugfix_test.dart` | Adding a product with stock, safe deletion of a business |
| `test/staff_ui_test.dart` | What a cashier can and cannot see |
| `test/sync_test.dart` | Two devices through a fake Google Drive: both see each other's work, stock adds up, renames survive, later edits win, deletes travel, no duplicate invoice numbers |
| `test/google_test.dart` | Google Drive requests, and the Windows sign-in (PKCE, token refresh, revoked sign-in, Google Drive box left unticked, asking again, a late answer after log out) |
| `test/drive_access_test.dart` | Shops going to Google Drive by themselves: only the owner's own shop, not while locked or for staff, paused shops left alone, retry after no internet, a half-finished first upload finished later, the Allow button and the first-run shop list |
| `test/pos_cart_test.dart` | The cart: delivery charge, full and part due, customer by phone or name (no duplicates, shared names), saved customers, short phone numbers refused, `F9` / `Ctrl+Enter`, phone and desktop layouts in both languages |
| `test/sale_detail_test.dart` | Sale page and shared message with a delivery charge |
| `test/website_test.dart` | WooCommerce import against a fake store: matching, totals, status changes, no duplicates, stock options; the BizKhata JSON format |
| `test/order_finder_test.dart` | Recognising order lists in what admin panels load: Mongo/Express, Laravel, WooCommerce-like and Shopify-like JSON, wrapped search results, HTML tables, pasted sheets; product, customer and sales lists are not taken for orders; money and date formats |
| `test/browser_connector_test.dart` | Reading a website through the built-in browser against a fake admin panel: all statuses, bigger pages and paging worked out, first full read then recent pages only, status changes followed, signed out, a login page instead of data, a site that ignores page numbers, tables, pasted orders |
| `integration_test/browser_test.dart` | The real built-in browser (WebView2 on Windows) against a local test website: sign in, spot and check the list, then read every page from the hidden browser with the site's own sign-in (`flutter test integration_test/browser_test.dart -d windows`) |
| `test/screens_test.dart` | Every screen and the main dialogs in both languages at five window sizes, failing on any layout overflow |

`test/shots_test.dart` is skipped by default. It renders the screenshots into `test/goldens/`:

```bash
flutter test test/shots_test.dart --run-skipped --update-goldens
```

## Building releases

### Windows

```powershell
powershell -ExecutionPolicy Bypass -File tool\release_windows.ps1
```

This builds the app and puts `BizKhata-Setup-<version>.exe` and `BizKhata-<version>-windows-portable.zip` in `build\release-<version>\`. Google sign-in is included when `google_oauth.json` exists. It needs [Inno Setup 6](https://jrsoftware.org/isinfo.php); if `ISCC.exe` isn't in the usual place, add `-Iscc <path to ISCC.exe>`. The installer installs per user, and uninstalling keeps your business data.

The Windows app is a folder, not a single file: `bizkhata.exe` needs the DLLs and the `data` folder next to it (all of `build\windows\x64\runner\Release\`). Started without them, it explains this in English and Bangla instead of Windows' "...dll was not found". The C++ runtime is linked into the exe and the plugin DLLs, so PCs don't need the Microsoft Visual C++ Redistributable.

### Android

```powershell
flutter build apk --release --split-per-abi --dart-define-from-file=google_oauth.json   # APKs to install directly
flutter build appbundle --release --dart-define-from-file=google_oauth.json             # bundle for Google Play
```

Release builds fall back to the debug key unless `android/key.properties` exists. To sign with your own key:

```powershell
keytool -genkeypair -keystore upload.jks -storetype PKCS12 -keyalg RSA -keysize 2048 -validity 10000 -alias upload
```

```properties
# android/key.properties
storePassword=your-password
keyPassword=your-password
keyAlias=upload
storeFile=C:/path/to/upload.jks
```

Git ignores both files, so back them up yourself. An APK signed with a different key can't install over an existing copy: back up the shop's data, uninstall, install the new APK, then restore.

The store text and data-safety answers are in [docs/play-store-listing.md](docs/play-store-listing.md).

### Linux and macOS

The platform folders are included, but these builds haven't been tried yet. Flutter builds a desktop app only on the system it targets.

## Working on the code

- All user-facing text lives in `lib/core/i18n.dart`, in `enum T`, with English and Bangla side by side. Add both.
- Generated database code (`*.g.dart`) is committed, so a fresh clone builds without running `build_runner`.
- To change the database, edit `lib/data/database.dart`, bump `schemaVersion`, add the step to `onUpgrade`, then run:

  ```bash
  dart run build_runner build
  dart run drift_dev schema dump lib/data/database.dart drift_schemas/
  dart run drift_dev schema generate drift_schemas/ test/generated_migrations/
  ```

  and add the new version to `test/migration_test.dart`.
- Screens have to hold up from a 390 px wide phone to a 1366×768 laptop. `test/screens_test.dart` fails on layout overflows at those sizes.

## Status and plans

Windows is the main target. Android builds, and version 1.0 was run through a full sale on an emulator. Google sign-in has been tried on Windows with the live Google project (version 1.2.1).

Not yet tried with real accounts or hardware: live courier bookings, SMS gateways, thermal printers, camera scanning on a physical phone, Google sign-in on a physical Android phone, and a live WooCommerce store. Sync, Drive requests, sign-in, log-out, website imports and status updates sent back to a website are covered by automated tests against fakes. Reading orders through the built-in browser is tested against fake admin panels and, with the real WebView2 browser on Windows, against a local test website, but not yet against live admin panels.

Ideas for later: bKash/Nagad payment links, courier and website webhooks instead of polling, Shopify, sending stock back to the website, Linux and macOS builds.

## License

No open-source license has been chosen, so all rights are reserved for now.

The bundled fonts, Hind Siliguri and Bricolage Grotesque, are under the SIL Open Font License. The license texts are in `assets/fonts/`.
