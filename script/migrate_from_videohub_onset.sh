#!/usr/bin/env bash
# Carries settings and saved data across the "Videohub On-Set" → "Videohub CNTRL"
# rename.
#
# The rename changed the bundle identifier, which moves the app's sandbox
# container. A sandboxed app cannot read another app's container, so the app
# itself is not allowed to do this — it has to happen from outside, here.
#
# Copies rather than moves, so the old app keeps working if you roll back. Never
# overwrites anything already saved under the new name, so it is safe to run
# twice.

set -euo pipefail

OLD_BUNDLE_ID="com.videohubonset.VideohubOnSet"
NEW_BUNDLE_ID="com.videohubcntrl.VideohubCNTRL"
OLD_FOLDER="Videohub On-Set"
NEW_FOLDER="Videohub CNTRL"
STORE_FILES=("TileCustomizations.json" "Salvos.json")

DRY_RUN=1
[[ "${1:-}" == "--write" ]] && DRY_RUN=0

CONTAINERS="$HOME/Library/Containers"
OLD_DATA="$CONTAINERS/$OLD_BUNDLE_ID/Data"
NEW_DATA="$CONTAINERS/$NEW_BUNDLE_ID/Data"

say() { printf '%s\n' "$*"; }
run() {
  if (( DRY_RUN )); then
    say "  would: $*"
  else
    "$@"
  fi
}

if [[ ! -d "$OLD_DATA" ]]; then
  say "No sandbox container for $OLD_BUNDLE_ID."
  say "Nothing to migrate — either you never ran the old build, or it ran unsandboxed."
  exit 0
fi

if [[ ! -d "$NEW_DATA" ]]; then
  say "The new app has no container yet."
  say "Launch Videohub CNTRL once, quit it, then run this again."
  exit 1
fi

say "From : $OLD_DATA"
say "To   : $NEW_DATA"
say ""

# --- Saved stores -----------------------------------------------------------
OLD_SUPPORT="$OLD_DATA/Library/Application Support/$OLD_FOLDER"
NEW_SUPPORT="$NEW_DATA/Library/Application Support/$NEW_FOLDER"

migrated=0
for file in "${STORE_FILES[@]}"; do
  if [[ ! -f "$OLD_SUPPORT/$file" ]]; then
    say "skip  $file — not present in the old container"
    continue
  fi
  if [[ -f "$NEW_SUPPORT/$file" ]]; then
    say "skip  $file — already exists under the new name, leaving it alone"
    continue
  fi
  say "copy  $file"
  run mkdir -p "$NEW_SUPPORT"
  run cp "$OLD_SUPPORT/$file" "$NEW_SUPPORT/$file"
  migrated=$((migrated + 1))
done

# --- Preferences ------------------------------------------------------------
# The router host, auto-reconnect, confirm-before-TAKE and the control server
# settings all live in UserDefaults, which is keyed on the bundle identifier.
OLD_PREFS="$OLD_DATA/Library/Preferences/$OLD_BUNDLE_ID.plist"

if [[ -f "$OLD_PREFS" ]]; then
  existing_host="$(defaults read "$NEW_BUNDLE_ID" videohub.host 2>/dev/null || true)"
  if [[ -n "$existing_host" ]]; then
    say "skip  preferences — new app already has a router host set ($existing_host)"
  else
    say "copy  preferences (router host, reconnect, TAKE confirmation, control port)"
    if (( DRY_RUN )); then
      say "  would: defaults import $NEW_BUNDLE_ID $OLD_PREFS"
    else
      # `defaults import` merges into the live domain and notifies cfprefsd,
      # which copying the plist by hand does not.
      defaults import "$NEW_BUNDLE_ID" "$OLD_PREFS"
      migrated=$((migrated + 1))
    fi
  fi
else
  say "skip  preferences — none found in the old container"
fi

say ""
if (( DRY_RUN )); then
  say "Preview only. Re-run with --write to copy."
else
  say "Migrated $migrated item(s). Relaunch Videohub CNTRL."
  say "The old container is untouched at:"
  say "  $OLD_DATA"
  say "Delete it once you're satisfied nothing is missing."
fi
