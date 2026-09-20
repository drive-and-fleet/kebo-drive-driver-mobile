#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ORG="${FLUTTER_ORG:-hu.fleetplatform}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if ! command -v flutter >/dev/null 2>&1; then
  echo "HIBA: a flutter parancs nem található a PATH-ban." >&2
  exit 1
fi

if [ -d "$ROOT/android" ] && [ -d "$ROOT/ios" ]; then
  echo "android/ és ios/ már létezik; nem írom felül."
  exit 0
fi

flutter create \
  --platforms=android,ios \
  --org "$ORG" \
  --project-name fleet_driver_app \
  "$TMP/scaffold"

[ -d "$ROOT/android" ] || cp -R "$TMP/scaffold/android" "$ROOT/android"
[ -d "$ROOT/ios" ] || cp -R "$TMP/scaffold/ios" "$ROOT/ios"
python3 "$ROOT/tool/patch_platforms.py" "$ROOT"

echo "Platform scaffold elkészült. Következő: flutter pub get"
