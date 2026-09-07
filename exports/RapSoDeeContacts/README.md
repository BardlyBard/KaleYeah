# RapSoDee contacts export

Private backup staging for the shared RapSoDee address book (`contacts.json`).

- **Source of truth:** sandboxed `Application Support/RapSoDeeContacts/contacts.json` (bundle `local.rapsodee.mail`)
- **Do not** sync into Outlook or Gmail native contacts
- **Do not** create a public GitHub repo for this folder
- Run `Scripts/backup-contacts.sh` after Sync / Rebuild, then push to a **private** repo if desired

Autofill in Compose uses this shared book regardless of which From account is selected.
