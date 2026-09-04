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

### Where to paste the Application (client) ID

1. **Default client ID** (public client, no secret): `3f7dfcbe-daee-4902-a5db-cc779ad45c4b` — baked into `MSALAppConfig.defaultClientID` and Info.plist `MSALClientID`.
2. **Override without rebuild:** Settings → Microsoft 365 → **Application (client) ID** (UserDefaults `rapSoDee.msal.clientID`).

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
9. Click **Grant admin consent** for the tenant if you are an admin (recommended for Kale Yeah).
10. In RapSoDee Settings → paste the client ID → **Sign in with Microsoft** (prefer `derek.brown@kaleyeahinspections.com`) → **Sync now**.

Scopes used by the app: `Mail.Read Mail.ReadWrite Mail.Send User.Read` (MSAL adds reserved OIDC scopes itself; do not pass `openid`/`profile`/`offline_access` to acquireToken).

### Behaviour

- **Sign in / Sign out / Sync** in Settings; signed-in account shown.
- Graph lists recent Inbox + Sent; HTML bodies map into the existing reading pane.
- Compose / reply send via Graph `sendMail`.
- Gmail App Password path is unchanged.
- Basic M365 password UI is removed (basic auth is disabled).

### After Allow (OAuth return)

RapSoDee uses MSAL **ASWebAuthenticationSession** (`webviewType = .authenticationSession`) with URL scheme `msauth.local.rapsodee.mail` (Info.plist `CFBundleURLTypes`) and Entra redirect **`msauth.local.rapsodee.mail://auth`**.

1. Tap **Sign in with Microsoft** → system auth UI / browser appears.
2. Sign in and tap **Allow**.
3. **Expected:** auth UI dismisses and **RapSoDee comes forward** signed in, then sync starts.
4. If Safari still shows a blank “you can close this” page, click back to RapSoDee once. If Settings says *Only one interactive session is allowed at a time*, tap **Clear stuck sign-in** / **Cancel sign-in / sync**, then Sign in again (RapSoDee cancels the orphan session and retries once automatically).

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

- Follows **system appearance** (light/dark).
- Soft per-account row tints; Approve uses a loud but friendly accent; live Gmail uses Google-red tint; Microsoft 365 uses Outlook-blue tint.
- `MailStore` is the seam for backends — Stage 1 ships `DemoMailStore` with optional Gmail IMAP/SMTP + Microsoft 365 MSAL/Graph.

## Regenerate Xcode project

```bash
xcodegen generate
```
