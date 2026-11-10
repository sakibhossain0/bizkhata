# Setting up Google sign-in and Drive sync

BizKhata saves a shop in the user's own Google Drive, in a hidden app folder that only BizKhata can
open, and keeps every device that opens the shop in step. For that, the app needs OAuth client ids
from a Google Cloud project that **you** (the publisher of this copy of the app) own. You set this
up once; your users only press **Sign in with Google**.

The app asks for these scopes only:

| Scope | Why | Google's class |
|---|---|---|
| `openid`, `email`, `profile` | show who is signed in | non-sensitive |
| `https://www.googleapis.com/auth/drive.appdata` | the app's own hidden folder in Drive | non-sensitive |

Because there are no sensitive or restricted scopes, Google does not require a security review.

## 1. Create the project

1. Open <https://console.cloud.google.com/> and create a project, e.g. **BizKhata**.
2. **APIs & Services → Library** → search **Google Drive API** → **Enable**.

## 2. Consent screen

**Google Auth Platform** (formerly *OAuth consent screen*):

1. **Branding**: app name `BizKhata`, your support email, optionally the logo
   (`assets/brand/icon-1024.png`, resized to 120×120) and the privacy policy link
   (`https://github.com/sakibhossain0/bizkhata/blob/main/docs/privacy-policy.md`).
2. **Audience**: *External*. While the app is in **Testing**, only the test users you add can sign
   in, and Google signs them out after 7 days. When it works, press **Publish app** so anyone can
   sign in and stays signed in.
3. **Data access** → **Add or remove scopes**: `openid`, `.../auth/userinfo.email`,
   `.../auth/userinfo.profile`, `.../auth/drive.appdata`.

## 3. Client ids

**Google Auth Platform → Clients → Create client**, three times:

| Type | Used by | What to copy |
|---|---|---|
| **Desktop app** | Windows (browser sign-in) | Client ID **and** client secret |
| **Web application** (no redirect URIs needed) | Android: Google requires it as the "server client id" | Client ID |
| **Android** | Android | nothing to copy; it unlocks sign-in for your signing keys |

For the **Android** client: package name `com.bizkhata.bizkhata`, plus the **SHA-1** of every key
that signs the app. Make one Android client per SHA-1:

```powershell
# your upload key (release builds); the password is in android/key.properties
keytool -list -v -keystore E:\dev\keys\bizkhata-upload.jks -alias upload

# the debug key (flutter run)
keytool -list -v -keystore $env:USERPROFILE\.android\debug.keystore -alias androiddebugkey -storepass android
```

After you upload to Google Play, also add the **App signing key** SHA-1 from
*Play Console → Test and release → App integrity*, because Play re-signs the app.

## 4. Give the ids to the build

Create `google_oauth.json` in the project folder (it is git-ignored, see `google_oauth.example.json`):

```json
{
  "GOOGLE_DESKTOP_CLIENT_ID": "1234-abc.apps.googleusercontent.com",
  "GOOGLE_DESKTOP_CLIENT_SECRET": "GOCSPX-...",
  "GOOGLE_WEB_CLIENT_ID": "1234-def.apps.googleusercontent.com"
}
```

Then add `--dart-define-from-file=google_oauth.json` to every run and build:

```powershell
flutter run -d windows --dart-define-from-file=google_oauth.json
flutter build windows --release --dart-define-from-file=google_oauth.json
flutter build apk --release --split-per-abi --dart-define-from-file=google_oauth.json
flutter build appbundle --release --dart-define-from-file=google_oauth.json
```

Without the file the app works as before and simply hides Google sign-in. (Google treats a desktop
app's client secret as not truly secret, since it ships inside the app, but keep it out of git
anyway: GitHub's secret scanning flags it.)

## 5. Try it

1. On the PC: **Settings → Google Drive & devices → Sign in with Google**, finish in the browser,
   then **Save this shop to Google Drive**.
2. On a phone or second PC: on the first screen (or the business switcher) choose
   **Open a shop from Google Drive** and pick the shop.
3. Sell something on each device; within a minute both show both sales.

## How the sync works

* Each device works on its own copy and keeps working offline.
* Every change is recorded and uploaded as a small batch file about once a minute (sooner after a
  change), and the other devices apply each other's batches.
* When two devices change the same record, the later change is kept. Stock is not overwritten:
  every stock movement is its own record, so sales on two devices both come off the stock.
* Each device numbers its own invoices with a letter (`INV-1050` on the first, `INV-B1001` on the
  second) and creates records in its own id range, so nothing collides.
* A full copy is uploaded weekly so new devices start fast; old batch files are tidied after 45
  days, and a device that was away longer downloads a fresh copy automatically.
* Product photos and the logo are uploaded too.
* Settings that belong to one device (backup folder, printer, invoice counter) are not synced.
