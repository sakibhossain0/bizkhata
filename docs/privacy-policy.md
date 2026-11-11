# BizKhata privacy policy

_Last updated: 11 November 2026_

BizKhata is a stock, khata (credit ledger), sales and courier app for small shops. This policy
explains what happens to the information you put into it.

## The short version

Your shop's data stays on your own phone or computer, and in your own Google Drive if you choose.
You sign in with your Google account, but we do not run a server and never receive your products,
customers, sales or money records.

## What the app stores, and where

Everything you enter (business details, products, customers and suppliers, sales, purchases,
expenses, khata entries, staff names and PIN codes) is saved in a database file on your device.
PIN codes are stored as salted one-way hashes, not as the numbers themselves.

The app makes an automatic backup copy once a day, also on your device. Backup files you choose
to save or share go wherever you send them (for example Google Drive, email or another phone).

## Google account

BizKhata asks you to sign in with Google before you use it. It keeps your name and email address
on the device to show who is signed in and to keep each shop with the account that made it, so
another person signing in on the same computer doesn't see your shops. Google's sign-in token is
kept on the device (encrypted for your Windows user on Windows). Log out in Settings → *Account ·
Log out* or from the shop menu.

## Google Drive (optional)

If you turn on Google Drive sync, BizKhata stores your shop's data in a hidden app folder in
**your own** Google Drive, so you can open the same shop on your other devices. Only BizKhata can
see that folder, it uses your Drive storage, and it is reached directly from your devices with your
own Google sign-in. We never receive it. BizKhata asks Google only for your name, email address and
access to its own hidden folder, not to your other Drive files. You can remove the data at any time
in Google Drive (*Settings → Manage apps → BizKhata → Delete hidden app data*).

## When information leaves your device

Only when you ask for it, and only to the service you chose:

- **Couriers (Steadfast, Pathao, RedX):** when you book a parcel, the app sends the order number,
  the recipient's name, phone number, address, cash-on-delivery amount and your note to that
  courier, using the API keys you entered. When you check a customer's delivery record, it sends
  the customer's phone number to Steadfast. Each courier's own privacy policy applies to what it
  receives.
- **Your website:** if you connect a store (WooCommerce or your own site), the app reads orders
  and products from it with the address and keys you entered. With your own site, it also sends
  the website the new status of its orders when you change them in BizKhata (and the courier name
  and tracking code when you book a parcel). Nothing else is sent to the website.
- **Any website, through the built-in browser:** if you choose *Any website (sign in)*, your website
  opens in a browser inside BizKhata, on this device. You type your password into the website's own
  page; BizKhata doesn't read or keep it. BizKhata reads the order lists your admin panel loads and
  later asks your website for the same lists again from this device, to see new orders. It sends
  nothing else to the website and changes nothing there. The browser's cookies (your website
  sign-in) stay on this device, in a separate folder for each shop that backups and Google Drive
  never include.
- **SMS:** if you set up your own SMS gateway, reminders and order messages are sent through it to
  the customer's number.
- **WhatsApp and sharing:** receipts, reminders and backups open in WhatsApp or the system share
  sheet; you choose the recipient and press send yourself.

## Permissions

- **Camera:** used only while the barcode scanner is open. Images are not saved or sent anywhere.
- **Internet:** used only for Google sign-in, Google Drive sync, and the courier, website, SMS and
  WhatsApp features above.

## No ads, no tracking

BizKhata contains no advertising and no analytics or tracking libraries.

## Children

BizKhata is a business tool and is not directed at children.

## Deleting your data

Delete a business from Settings → About → Delete this business (it can be restored for 30 days
from "Recently deleted"), or uninstall the app to remove everything. Backup files you saved
elsewhere must be deleted there.

## Contact

Questions about this policy: open an issue at
<https://github.com/sakibhossain0/bizkhata/issues>, or write to the support email shown on
Google's sign-in screen for BizKhata.
