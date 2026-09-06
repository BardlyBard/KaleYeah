#!/bin/bash
# Parks one Callie→Derek draft in RapSoDee Approve on next launch (does NOT send).
set -euo pipefail
defaults write local.rapsodee.mail rapSoDee.injectApproveTestDraft -bool true
APP="${1:-/Users/derekbrown/Developer/KaleYeah/.derivedData/Build/Products/Debug/RapSoDee.app}"
if [[ -d "$APP" ]]; then
  # Kill existing then relaunch with inject arg as belt-and-suspenders.
  pkill -x RapSoDee 2>/dev/null || true
  sleep 0.5
  open -a "$APP" --args --inject-approve-test
  echo "Launched RapSoDee with Approve test draft inject."
else
  echo "Set defaults flag. Build/open RapSoDee (or pass .app path) to inject."
fi
