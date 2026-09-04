# RapSoDee

Native **SwiftUI macOS** mail client for Kale Yeah! — muse theme (warm paper + leaf-green accents). Playful, cute, almost professional.

Companion names (README only): lists app **Strophe**, schedule leaning **Tempo**. Related checklist app: [Calliope Lists](../calliope-lists) (separate repo).

**Bundle ID:** `local.rapsodee.mail`  
**Stage 1+:** Demo / mock mail store **plus optional live IMAP accounts** — Gmail and Microsoft 365 / GoDaddy Email Essentials (IMAP fetch + SMTP send). Passwords live in **macOS Keychain only** — never in source, git, or chat logs.

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

On first launch the demo store seeds two human accounts plus **Calliope**, folders, flags, and sample mail. Live Gmail and Microsoft 365 are optional — without Keychain credentials the UI stays demo-only.

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

## Connect Kale Yeah Microsoft 365 (GoDaddy Email Essentials)

**Never commit or chat the mailbox password.** RapSoDee stores it only in the macOS Keychain.

1. Use the GoDaddy / Microsoft 365 mailbox password for `derek.brown@kaleyeahinspections.com` (the same password you use for Outlook web / mail apps — not a Google App Password).
2. In RapSoDee: **Settings → Accounts — Microsoft 365**
   - Email defaults to `derek.brown@kaleyeahinspections.com` (editable).
   - Enter the **mailbox password** in the secure field.
   - Tap **Add Microsoft 365** / **Save Password**, then **Test connection** and **Sync now**.
3. Toggle **include in Unified Inbox** under *Unified Inbox — per-account toggles* if you want Kale Yeah mail mixed with Gmail.
4. Replies use **deliveredTo** (the Kale Yeah address) as From when you reply to an M365 message.
5. On later launches, if Keychain still has the password, RapSoDee syncs this account alongside Gmail.

IMAP: `outlook.office365.com:993` (SSL). SMTP: `smtp.office365.com:587` (STARTTLS; falls back to 465 if needed). Username is the full email address. HTML MIME rendering is shared with Gmail.

## Project layout

```
RapSoDee/
  RapSoDeeApp.swift          # SwiftData container + compose pop-out window
  Theme/MuseTheme.swift      # Paper / leaf muse palette
  Models/                    # Mail + SwiftData settings models
  Store/MailStore.swift      # Protocol for future IMAP/Exchange/Graph
  Store/DemoMailStore.swift  # Demo store + hybrid live Gmail / M365 merge
  Services/                  # Keychain, IMAP/SMTP, shared IMAP connector (Gmail + Office 365)
  Views/                     # 3-pane UI, compose, settings, sheets
project.yml                  # XcodeGen spec
```

## Stage 1 vs Later

| Stage 1 (this repo) | Later |
|---------------------|--------|
| 3-pane: ladder \| flat list (no threading) \| reading/compose | Broader providers (Exchange / Graph / OAuth) |
| Demo multi-account + optional live Gmail + Microsoft 365 | OAuth / Graph / more providers |
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
- `MailStore` is the seam for backends — Stage 1 ships `DemoMailStore` with optional Gmail + Microsoft 365 IMAP/SMTP.

## Regenerate Xcode project

```bash
xcodegen generate
```
