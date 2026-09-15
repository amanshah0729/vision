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
  xcodegen generate >/dev/null
  xcodebuild -project SensorAgent.xcodeproj -scheme SensorAgent -sdk iphoneos \
    -destination "id=$DEVICE_UDID" -allowProvisioningUpdates \
    DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" \
    CODE_SIGN_STYLE=Automatic -derivedDataPath "$DD" build 2>&1 \
    | grep -E "error:|BUILD (SUCCEEDED|FAILED)" | sort -u
}
install() { xcrun devicectl device install app --device "$DEVICE_UDID" "$APP" 2>&1 | grep -iE "installed|error"; }
# The `--` is required: without it devicectl parses -autoStartCameraPoC as its own flag.
run() { xcrun devicectl device process launch --terminate-existing --device "$DEVICE_UDID" "$BUNDLE_ID" -- -autoStartCameraPoC 2>&1 | grep -E "Launched|Locked|error"; }
pull() { xcrun devicectl device copy from --device "$DEVICE_UDID" --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" --source "Documents/$1" --destination "./$1" >/dev/null && echo "./$1"; }

case "${1:-}" in
  build) build ;;
  install) install ;;
  run) run ;;
  log) pull poc.log && tail -20 poc.log ;;
  photo) pull last-photo.jpg ;;
  all) build && install && run ;;
  *) echo "usage: $0 build|install|run|log|photo|all"; exit 1 ;;
esac
