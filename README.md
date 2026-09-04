# RapSoDee

Native **SwiftUI macOS** mail client for Kale Yeah! — muse theme (warm paper + leaf-green accents). Playful, cute, almost professional.

Companion names (README only): lists app **Strophe**, schedule leaning **Tempo**. Related checklist app: [Calliope Lists](../calliope-lists) (separate repo).

**Bundle ID:** `local.rapsodee.mail`  
**Stage 1:** Demo / mock mail store with a real 3-pane Mac UI. Live IMAP / Exchange / Graph sync is **out of scope**.

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

On first launch the demo store seeds two human accounts plus **Calliope**, folders, flags, and sample mail (including Approve drafts and blocked attachment types).

### CLI build (optional)

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodegen generate
xcodebuild -scheme RapSoDee -destination 'platform=macOS' -configuration Debug build
```

## Project layout

```
RapSoDee/
  RapSoDeeApp.swift          # SwiftData container + compose pop-out window
  Theme/MuseTheme.swift      # Paper / leaf muse palette
  Models/                    # Mail + SwiftData settings models
  Store/MailStore.swift      # Protocol for future IMAP/Exchange/Graph
  Store/DemoMailStore.swift  # Stage 1 mock store + seed
  Views/                     # 3-pane UI, compose, settings, sheets
project.yml                  # XcodeGen spec
```

## Stage 1 vs Later

| Stage 1 (this repo) | Later |
|---------------------|--------|
| 3-pane: ladder \| flat list (no threading) \| reading/compose | Live server sync (IMAP / Exchange / Graph) |
| Demo multi-account `MailStore` | Real credentials & OAuth (never commit secrets) |
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
- Soft per-account row tints; Approve uses a loud but friendly accent.
- `MailStore` is the seam for real backends — Stage 1 ships `DemoMailStore` only.

## Regenerate Xcode project

```bash
xcodegen generate
```
