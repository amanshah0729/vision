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

build() {
  # gen.sh writes Team.xcconfig, so a later `open SensorAgent.xcodeproj` signs the same way.
  DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" BUNDLE_ID="$BUNDLE_ID" ./gen.sh >/dev/null
  # -allowProvisioningUpdates only on request: with it, Xcode may mint a fresh development
  # certificate on every build, and each new private key triggers a keychain password
  # prompt loop for codesign. PROVISION=1 ./device.sh build for the first build on a machine.
  xcodebuild -project SensorAgent.xcodeproj -scheme SensorAgent -sdk iphoneos \
    -destination "id=$DEVICE_UDID" ${PROVISION:+-allowProvisioningUpdates} \
    -derivedDataPath "$DD" build 2>&1 \
    | grep -E "error:|BUILD (SUCCEEDED|FAILED)" | sort -u
}
install() { xcrun devicectl device install app --device "$DEVICE_UDID" "$APP" 2>&1 | grep -iE "installed|error"; }
# The `--` is required: without it devicectl parses -autoStartCameraPoC as its own flag.
run() { xcrun devicectl device process launch --terminate-existing --device "$DEVICE_UDID" "$BUNDLE_ID" -- -autoStartCameraPoC 2>&1 | grep -E "Launched|Locked|error"; }
# bridge <url> <token>: connect the agent to a bridge on launch (the real end-to-end mode).
bridge() { xcrun devicectl device process launch --terminate-existing --device "$DEVICE_UDID" "$BUNDLE_ID" -- -autoStartAgent -bridgeURL "$1" -bridgeToken "$2" 2>&1 | grep -E "Launched|Locked|error"; }
pull() { xcrun devicectl device copy from --device "$DEVICE_UDID" --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" --source "Documents/$1" --destination "./$1" >/dev/null && echo "./$1"; }

case "${1:-}" in
  build) build ;;
  install) install ;;
  run) run ;;
  bridge) bridge "${2:?url}" "${3:?token}" ;;
  log) pull poc.log && tail -20 poc.log ;;
  photo) pull last-photo.jpg ;;
  all) build && install && run ;;
  *) echo "usage: $0 build|install|run|bridge <url> <token>|log|photo|all"; exit 1 ;;
esac
