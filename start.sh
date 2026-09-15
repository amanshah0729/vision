#!/usr/bin/env bash
# Start the Vision bridge and hold the Mac awake while it runs.
#
#   ./start.sh            → bridge on $PORT (default 8791)
#
# No --tunnel flag here on purpose: the public hostname comes from the shared named
# tunnel in ../tunnel/config.yml (vision.orthosoftwaresucks.com → :8791),
# run by the com.glasses.tunnel LaunchAgent. One tunnel, many apps.
#
# The token lives in .token so the URL saved on the glasses and the phone survives
# restarts. Delete the file to rotate it (then re-enter it on both).
set -euo pipefail
cd "$(dirname "$0")"

if [ ! -f .token ]; then
  head -c 12 /dev/urandom | base64 | tr -d '/+=' > .token
  chmod 600 .token
  echo "generated a new token → .token"
fi
TOKEN="$(cat .token)"
PORT="${PORT:-8791}"
[ -f .env ] && set -a && . ./.env && set +a

GLASSES_TOKEN="$TOKEN" PORT="$PORT" exec caffeinate -i node server.js
