#!/usr/bin/env bash
# Build, install and drive SensorAgent on a real iPhone from the Mac, no Xcode GUI.
# Reads .device.env (gitignored) beside this script. Usage: ./device.sh build|install|run|log|photo|all
set -euo pipefail
cd "$(dirname "$0")"
[ -f .device.env ] || { echo "copy .device.env.example to .device.env and fill it in"; exit 1; }
# shellcheck disable=SC1091
source .device.env
: "${DEVICE_UDID:?}" "${DEVELOPMENT_TEAM:?}" "${BUNDLE_ID:?}"
DD=${DERIVED_DATA:-/tmp/sensoragent-device}
APP="$DD/Build/Products/Debug-iphoneos/SensorAgent.app"

# A dedicated keychain with an EMPTY password for the signing key. macOS lets codesign use a
# key there without the "codesign wants to access key" prompt, which otherwise appears on
# every build after the one that minted the key and needs the Mac login password. Xcode
# mints keys into the *default* keychain, so `PROVISION=1` builds make this the default for
# the duration of the build and restore the login keychain afterwards.
KC="$HOME/Library/Keychains/sensoragent-build.keychain-db"
keychain() {
  [ -f "$KC" ] || security create-keychain -p "" "$KC"
  security set-keychain-settings "$KC"            # never auto-lock
  security unlock-keychain -p "" "$KC"
  # Add to the search list (idempotent) without dropping the existing entries.
  security list-keychains -d user -s "$KC" $(security list-keychains -d user | tr -d '" ' | grep -v "$(basename "$KC")")
  echo "build keychain ready: $KC"
}
grant() { security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "" "$KC" >/dev/null 2>&1 || true; }

build() {
  # gen.sh writes Team.xcconfig, so a later `open SensorAgent.xcodeproj` signs the same way.
  DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" BUNDLE_ID="$BUNDLE_ID" ./gen.sh >/dev/null
  # -allowProvisioningUpdates only on request (PROVISION=1): it may mint a fresh development
  # certificate. When it does, the key goes to the build keychain (see above) so later
  # builds stay silent.
  local orig=""
  if [ -n "${PROVISION:-}" ]; then
    keychain >/dev/null
    orig=$(security default-keychain -d user | tr -d '" ')
    security default-keychain -d user -s "$KC"
  fi
  xcodebuild -project SensorAgent.xcodeproj -scheme SensorAgent -sdk iphoneos \
    -destination "id=$DEVICE_UDID" ${PROVISION:+-allowProvisioningUpdates} \
    -derivedDataPath "$DD" build 2>&1 \
    | grep -E "error:|BUILD (SUCCEEDED|FAILED)" | sort -u
  if [ -n "$orig" ]; then security default-keychain -d user -s "$orig"; grant; fi
}
install() { xcrun devicectl device install app --device "$DEVICE_UDID" "$APP" 2>&1 | grep -iE "installed|error"; }
# The `--` is required: without it devicectl parses -autoStartCameraPoC as its own flag.
run() { xcrun devicectl device process launch --terminate-existing --device "$DEVICE_UDID" "$BUNDLE_ID" -- -autoStartCameraPoC 2>&1 | grep -E "Launched|Locked|error"; }
# bridge <url> <token>: connect the agent to a bridge on launch (the real end-to-end mode).
bridge() { xcrun devicectl device process launch --terminate-existing --device "$DEVICE_UDID" "$BUNDLE_ID" -- -autoStartAgent -bridgeURL "$1" -bridgeToken "$2" 2>&1 | grep -E "Launched|Locked|error"; }
pull() { xcrun devicectl device copy from --device "$DEVICE_UDID" --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" --source "Documents/$1" --destination "./$1" >/dev/null && echo "./$1"; }

case "${1:-}" in
  build) build ;;
  keychain) keychain && grant ;;
  install) install ;;
  run) run ;;
  bridge) bridge "${2:?url}" "${3:?token}" ;;
  log) pull poc.log && tail -20 poc.log ;;
  photo) pull last-photo.jpg ;;
  all) build && install && run ;;
  *) echo "usage: $0 build|install|run|bridge <url> <token>|log|photo|keychain|all"; exit 1 ;;
esac
