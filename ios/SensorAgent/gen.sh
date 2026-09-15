#!/usr/bin/env bash
# Generate the Xcode project. Wraps `xcodegen generate` so the gitignored Team.xcconfig
# always exists — xcodegen fails hard on a missing configFiles entry.
#
#   ./gen.sh                         # simulator-only: empty team, ad-hoc signing works
#   DEVELOPMENT_TEAM=ABCDE12345 ./gen.sh   # device build: your Apple team ID
#
# Find the team ID in Xcode → Settings → Accounts → your Apple ID → Team ID, or at
# developer.apple.com/account → Membership. It must be a team on the PAID program: the
# Wi-Fi entitlements in project.yml cannot be provisioned on a free personal team.
set -euo pipefail
cd "$(dirname "$0")"

if [ -n "${DEVELOPMENT_TEAM:-}" ]; then
  printf 'DEVELOPMENT_TEAM = %s\n' "$DEVELOPMENT_TEAM" > Team.xcconfig
  echo "Team.xcconfig <- DEVELOPMENT_TEAM=$DEVELOPMENT_TEAM"
elif [ ! -f Team.xcconfig ]; then
  printf '// set DEVELOPMENT_TEAM = <your 10-char team id> for device builds\nDEVELOPMENT_TEAM =\n' > Team.xcconfig
  echo "Team.xcconfig <- empty (simulator only). Re-run with DEVELOPMENT_TEAM=... for a phone."
fi
xcodegen generate
