#!/bin/bash
# Copy RapSoDee contacts.json into the repo export folder for optional private GitHub backup.
# Does NOT create a GitHub repo. Push to a private contacts backup repo separately if desired.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EXPORT_DIR="$ROOT/exports/RapSoDeeContacts"
mkdir -p "$EXPORT_DIR"

APP_SUPPORT="$HOME/Library/Containers/local.rapsodee.mail/Data/Library/Application Support/RapSoDeeContacts/contacts.json"
FALLBACK="$HOME/Library/Application Support/RapSoDeeContacts/contacts.json"

SRC=""
if [[ -f "$APP_SUPPORT" ]]; then
  SRC="$APP_SUPPORT"
elif [[ -f "$FALLBACK" ]]; then
  SRC="$FALLBACK"
fi

if [[ -z "$SRC" ]]; then
  echo "No contacts.json found yet. Open RapSoDee, Sync or tap Rebuild from mail in Settings."
  exit 1
fi

cp -f "$SRC" "$EXPORT_DIR/contacts.json"
echo "Exported $(wc -l < "$EXPORT_DIR/contacts.json" | tr -d ' ') lines → $EXPORT_DIR/contacts.json"
echo "To back up privately: create a private GitHub repo, then:"
echo "  cd \"$EXPORT_DIR\" && git init && git add contacts.json && git commit -m \"contacts backup\" && git remote add origin git@github.com:YOU/PRIVATE-REPO.git && git push -u origin main"
