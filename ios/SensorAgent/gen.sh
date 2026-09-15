#!/usr/bin/env bash
# Generate the Xcode project. Wraps `xcodegen generate` so the gitignored Team.xcconfig
# always exists — xcodegen fails hard on a missing configFiles entry.
#
#   ./gen.sh                                   # simulator-only: empty team, ad-hoc signing
#   DEVELOPMENT_TEAM=ABCDE12345 ./gen.sh       # device build: your Apple team id
#   DEVELOPMENT_TEAM=… BUNDLE_ID=com.you.glasses.SensorAgent ./gen.sh   # + your bundle id
#
# Team id: Xcode → Settings → Accounts → your Apple ID → Team ID. A FREE Personal Team is
# enough — the camera streams over Bluetooth Classic on it. Only the optional Wi-Fi link
# (entitlements commented out in project.yml) needs the paid program.
# Keep BUNDLE_ID stable once the glasses have registered the app: changing it drops the
# DAT registration and Meta AI has to approve the app again.
set -euo pipefail
cd "$(dirname "$0")"

if [ -n "${DEVELOPMENT_TEAM:-}" ]; then
  {
    printf 'DEVELOPMENT_TEAM = %s\n' "$DEVELOPMENT_TEAM"
    [ -n "${BUNDLE_ID:-}" ] && printf 'PRODUCT_BUNDLE_IDENTIFIER = %s\n' "$BUNDLE_ID"
  } > Team.xcconfig
  echo "Team.xcconfig <- DEVELOPMENT_TEAM=$DEVELOPMENT_TEAM${BUNDLE_ID:+ BUNDLE_ID=$BUNDLE_ID}"
elif [ ! -f Team.xcconfig ]; then
  printf '// set DEVELOPMENT_TEAM = <your 10-char team id> for device builds\nDEVELOPMENT_TEAM =\n' > Team.xcconfig
  echo "Team.xcconfig <- empty (simulator only). Re-run with DEVELOPMENT_TEAM=... for a phone."
fi
xcodegen generate
