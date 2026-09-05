# RapSoDee

Native **SwiftUI macOS** mail client for Kale Yeah! — muse theme (warm paper + leaf-green accents). Playful, cute, almost professional.

Companion names (README only): lists app **Strophe**, schedule leaning **Tempo**. Related checklist app: [Calliope Lists](../calliope-lists) (separate repo).

**Bundle ID:** `local.rapsodee.mail`  
**Stage 1+:** Demo / mock mail store **plus optional live accounts** — Gmail (IMAP/SMTP App Password) and Microsoft 365 (MSAL + Graph). Secrets live in **macOS Keychain / MSAL cache only** — never in source, git, or chat logs.

## Open & run

1. Install **Xcode** from the Mac App Store (full Xcode.app required).
2. If `xcode-select` still points at Command Line Tools, either switch it or open the project in Xcode (Xcode uses its own toolchain):
   ```bash
   sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
   ```
3. From this directory, regenerate the project if needed:
   ```bash
   brew install xcodegen   # if needed
   xcodegen generate
   ```
4. Open `RapSoDee.xcodeproj` in Xcode.
5. Select the **RapSoDee** target → **Signing & Capabilities**:
   - Team: same Apple Development team used for Calliope Lists (`293476R5DQ` if that is your Personal/paid team).
   - Automatically manage signing.
6. Destination: **My Mac**.
7. Press **Run** (⌘R).

On first launch the demo store seeds two human accounts plus **Calliope**, folders, flags, and sample mail. Live Gmail and Microsoft 365 are optional — without Gmail Keychain credentials / Microsoft sign-in the UI stays demo-only.

### CLI build (optional)

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodegen generate
xcodebuild -scheme RapSoDee -destination 'platform=macOS' -configuration Debug -derivedDataPath .derivedData build
```

## Connect live Gmail (App Password)

**Never commit passwords or paste them into git / README / chat.** Credentials are stored only in the macOS Keychain via Settings.

1. In Google Account for `ci.derekbrown@gmail.com`, turn on **2-Step Verification**.
2. Open [Google App Passwords](https://myaccount.google.com/apppasswords) → create an app password (e.g. “RapSoDee”).
3. Copy the 16-character password (spaces optional).
4. In RapSoDee: **Settings → Accounts — Gmail**
   - Email defaults to `ci.derekbrown@gmail.com` (editable).
   - Paste the **Gmail App Password**.
   - Tap **Add Gmail** / **Save Password**, then **Test connection** and **Sync now**.
5. On later launches, if Keychain still has the password, RapSoDee syncs automatically. Demo accounts remain for UI without Gmail.

IMAP: `imap.gmail.com:993` (SSL). SMTP: `smtp.gmail.com:465` (SSL). Recent messages (≈50) from Inbox / Sent / Drafts when listable. Flags / file / snooze stay local-first for the live account.

## Connect Kale Yeah Microsoft 365 (MSAL + Graph)

Microsoft has **disabled basic IMAP/SMTP password auth** for many tenants (`A0001 NO Basic authentication is disabled`). RapSoDee uses **MSAL (public client)** + **Microsoft Graph** instead — no client secret, tokens in the macOS Keychain via MSAL.

### Exact redirect URI (register this in Entra)

```
msauth.local.rapsodee.mail://auth
```

Bundle ID: `local.rapsodee.mail` → URL scheme `msauth.local.rapsodee.mail`.

### Where to paste the Application (client) ID / Tenant ID

1. **Default client ID** (public client, no secret): `3f7dfcbe-daee-4902-a5db-cc779ad45c4b` — baked into `MSALAppConfig.defaultClientID` and Info.plist `MSALClientID`.
2. **Override without rebuild:** Settings → Microsoft 365 → **Application (client) ID** (UserDefaults `rapSoDee.msal.clientID`).
3. **Directory (tenant) ID** (single-tenant): `d0b3fdba-6d90-4e3a-9938-c7a29e2359ee` — baked into `MSALAppConfig.defaultTenantID`. Override in Settings (UserDefaults `rapSoDee.msal.tenantID`). Changing tenant recreates the MSAL app.

### Single-tenant authority (important)

This Entra app is registered as **Accounts in this organizational directory only**. MSAL must use:

```
https://login.microsoftonline.com/d0b3fdba-6d90-4e3a-9938-c7a29e2359ee
```

Do **not** use `https://login.microsoftonline.com/common` for this registration — that mismatch can hang or break the return after **Allow**.

### Entra app registration steps

1. Open [Microsoft Entra admin center](https://entra.microsoft.com) → **App registrations** → **New registration**.
2. Name e.g. `RapSoDee`.
3. **Supported account types:** Accounts in this organizational directory only (single tenant) *or* any org directory if you need broader sign-in. For GoDaddy / Kale Yeah M365, single-tenant for your directory is typical.
4. Click **Register**. Copy the **Application (client) ID**.
5. **Authentication** → **Add a platform** → **Mobile and desktop applications** (public client).
6. Add redirect URI: `msauth.local.rapsodee.mail://auth` → Save.
7. Under **Authentication**, enable **Allow public client flows** = **Yes** (no client secret).
8. **API permissions** → Microsoft Graph → **Delegated**:
   - `Mail.Read`
   - `Mail.ReadWrite`
   - `Mail.Send`
   - `User.Read`
9. **API permissions** → **APIs my organization uses** → **Office 365 Exchange Online** → **Delegated**:
   - `SMTP.Send` (scope string `https://outlook.office.com/SMTP.Send`) — required for the SMTP XOAUTH2 send fallback / Prefer SMTP setting. Grant admin consent after adding.
10. Click **Grant admin consent** for the tenant if you are an admin (recommended for Kale Yeah).
11. Ensure the mailbox has **Authenticated SMTP** enabled (Exchange admin / Microsoft 365 admin → Users → Mail → Manage email apps → Authenticated SMTP), or SMTP XOAUTH2 will fail even with a valid token.
12. In RapSoDee Settings → paste the client ID → **Sign in with Microsoft** (prefer `derek.brown@kaleyeahinspections.com`) → **Sync now**. Re-consent if prompted after adding `SMTP.Send`.

Scopes used by the app:
- Graph: `Mail.Read Mail.ReadWrite Mail.Send User.Read` (MSAL adds reserved OIDC scopes itself; do not pass `openid`/`profile`/`offline_access` to interactive `acquireToken`).
- SMTP AUTH (separate token / audience): `https://outlook.office.com/SMTP.Send`

### Behaviour

- **Sign in / Sign out / Sync** in Settings; signed-in account shown.
- Graph lists recent Inbox + Sent; HTML bodies map into the existing reading pane.
- **Compose send (default):** Graph `POST /me/messages` (draft) → `POST /me/messages/{id}/send`. Never sets `from` when sending as the signed-in user.
- **Replies:** Graph `createReply` / `createReplyAll` → PATCH → send.
- **SMTP fallback:** on Graph send failure (or Settings → **Prefer SMTP (XOAUTH2) for send**), submit via `smtp.office365.com:587` STARTTLS with SASL XOAUTH2. Status line names the path used (`draft→send`, `createReply→send`, `SMTP XOAUTH2`).
- Note: Graph `sendMail` one-shot was observed to NDR `550 5.7.708` AS(7910) for Kale→Gmail while OWA worked; draft→send matches Outlook compose more closely. NDRs are not knowable in-app.
- Gmail App Password path is unchanged.
- Basic M365 password UI is removed (basic auth is disabled).

### After Allow (OAuth return)

RapSoDee uses MSAL **ASWebAuthenticationSession** (`webviewType = .authenticationSession`) with URL scheme `msauth.local.rapsodee.mail` (Info.plist `CFBundleURLTypes`) and Entra redirect **`msauth.local.rapsodee.mail://auth`**, against the **single-tenant** authority above.

1. Tap **Sign in with Microsoft** → system auth UI / browser appears.
2. Sign in and tap **Allow**.
3. **Expected:** auth UI dismisses and **RapSoDee comes forward** signed in, then sync starts.
4. If Safari still shows a blank “you can close this” page, click back to RapSoDee once. If Settings says *Only one interactive session is allowed at a time*, tap **Clear stuck sign-in** / **Cancel sign-in / sync**, then Sign in again (RapSoDee cancels the orphan session and retries once automatically).
5. **If the browser still hangs after Allow:** use **Sign in with device code** in Settings. RapSoDee shows a copyable user code + `https://microsoft.com/devicelogin` (no app redirect). Enter the code in any browser; RapSoDee polls until signed in. (Implemented via OAuth device authorization grant — MSAL ObjC has no `acquireTokenWithDeviceCode` API.)


## Import EML (Zoho / backup → Microsoft 365)

Import `.eml` files into the signed-in Kale Yeah Microsoft 365 mailbox via Microsoft Graph so **OWA, RapSoDee, and Outlook** all see the mail. This is **not** PST import.

1. Sign in to Microsoft 365 in **Settings → Accounts — Microsoft 365** (silent token; use **Sign in with device code** if expired).
2. Tap **Sync** so Graph folder names appear (Inbox, **Sent Items**, Archive, customs).
3. Choose destination in Settings: **Inbox**, **Sent Items**, **Archive**, **Drafts**, synced customs, or a raw Graph folder id. Use **Sent Items** for Zoho/sent-file EMLs.
4. Optional: **New Folder** creates a Graph folder (also from the Kale Yeah account context menu).
5. Click **Import EML…** (also **File → Import EML…** / ⇧⌘I).
6. In the open panel, select a **folder** of `.eml` files and/or individual `.eml` files (recursive).
7. Watch progress (`N/M imported`); failures are listed; duplicates with the same `Message-ID` are skipped. After import, Sync refreshes.
6. When finished, RapSoDee runs **Sync** so the message list refreshes.

Notes:
- Prefers Graph MIME create (RFC822), then falls back to parsed JSON (`subject`, body, from/to/cc, dates, attachments).
- Dates are preserved when Graph accepts `receivedDateTime` / `sentDateTime` on create.
- Never commit `.eml` contents or tokens (see `.gitignore`).

## Project layout

```
RapSoDee/
  RapSoDeeApp.swift          # SwiftData container + compose pop-out window
  Theme/MuseTheme.swift      # Paper / leaf muse palette
  Models/                    # Mail + SwiftData settings models
  Store/MailStore.swift      # Protocol for future IMAP/Exchange/Graph
  Store/DemoMailStore.swift  # Demo store + hybrid live Gmail / M365 merge
  Services/                  # Keychain, IMAP/SMTP (Gmail), MSAL + Graph (Microsoft 365)
  Views/                     # 3-pane UI, compose, settings, sheets
project.yml                  # XcodeGen spec
```

## Stage 1 vs Later

| Stage 1 (this repo) | Later |
|---------------------|--------|
| 3-pane: ladder \| flat list (no threading) \| reading/compose | More providers / richer Graph features |
| Demo multi-account + optional live Gmail + M365 (MSAL/Graph) | More providers / richer Graph |
| Always-on search (from/subject/snippet) | Full-body server search |
| Unified Inbox with per-account Settings toggles | Rules engine |
| Approve mailbox for Calliope drafts (edit / Approve&Send / Reject) | Calliope agent pipeline |
| Reply / Reply All / Forward **from delivery address** | Multiple identities per account |
| Inline compose + pop-out window | Templates gallery |
| One signature per account (incl. Calliope) | Rich signature HTML |
| Named colored flags; inbox as working set | Tags (explicitly out of Stage 1) |
| Flag / File / Snooze / Archive; Delete recessed | Undo stack polish |
| Snooze presets 1d / 2d / 1w / 1mo / custom | Natural-language snooze |
| Sort + basic filters | Smart mailboxes beyond Inbox/Approve |
| Shortcuts: Archive, Flag, File, Snooze, Next/Prev | Customizable keybindings |
| Attachments: no auto-preview; PDF/image tap-preview; block exe/js/html | Safer quarantine + AV hooks |
| SwiftData persistence for settings & flags | Message cache DB |
| VIP / Junk+Train / Smart File / notification **stubs** | Full implementations |

## Design notes

- Permanent **light mode** (aqua); dark Muse theming stays disabled.
- Soft per-account row tints; Approve uses a loud but friendly accent; live Gmail uses Google-red tint; Microsoft 365 uses Outlook-blue tint.
- `MailStore` is the seam for backends — Stage 1 ships `DemoMailStore` with optional Gmail IMAP/SMTP + Microsoft 365 MSAL/Graph.

## Regenerate Xcode project

```bash
xcodegen generate
```
