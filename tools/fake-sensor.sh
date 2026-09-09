#!/usr/bin/env bash
# Impersonates the native sensor client so the whole pipeline can be exercised
# before any Swift exists. If this script works, the iOS app is just a better
# client speaking the same protocol.
#
#   ./tools/fake-sensor.sh agent          # act as the phone: register + obey commands
#   ./tools/fake-sensor.sh devices        # what the glasses would see
#   ./tools/fake-sensor.sh cmd mic.start  # what the glasses would send
#   ./tools/fake-sensor.sh say "hello"    # push a final transcript
#   ./tools/fake-sensor.sh read           # read transcripts back
#
# BASE/TOKEN default to the local bridge and the token in .env.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASE="${BASE:-http://localhost:8787}"
# The bridge persists its generated token to .token so the URL saved on the
# glasses survives a restart; .env only overrides it.
TOKEN="${TOKEN:-$(grep -E '^GLASSES_TOKEN=' "$DIR/.env" 2>/dev/null | cut -d= -f2- | tr -d '"'"'"' ')}"
[ -z "$TOKEN" ] && [ -f "$DIR/.token" ] && TOKEN="$(tr -d ' \n' < "$DIR/.token")"
DEV="${DEV:-fake-0001}"

if [ -z "$TOKEN" ]; then
  echo "no token: set TOKEN=... or GLASSES_TOKEN in .env" >&2
  exit 1
fi

api() { # method path [curl args...]
  local m="$1" p="$2"; shift 2
  local sep='?'; case "$p" in *\?*) sep='&';; esac
  curl -sS -X "$m" "$BASE$p${sep}k=$TOKEN" "$@"
}

jpost() { api "$1" "$2" -H 'Content-Type: application/json' -d "$3"; }

register() {
  jpost POST /api/sensors/register \
    "{\"deviceId\":\"$DEV\",\"name\":\"fake sensor\",\"caps\":[\"mic\",\"camera\"]}"
}

case "${1:-help}" in
  register) register; echo ;;

  devices)  api GET /api/sensors; echo ;;

  say)      jpost POST /api/sensors/transcript \
              "{\"deviceId\":\"$DEV\",\"text\":$(printf '%s' "${2:-hello}" | sed 's/"/\\"/g;s/^/"/;s/$/"/'),\"final\":true}"; echo ;;

  read)     api GET "/api/sensors/transcript?since=${2:-0}"; echo ;;

  cmd)      jpost POST /api/sensors/command \
              "{\"deviceId\":\"$DEV\",\"action\":\"${2:-mic.start}\"}"; echo ;;

  still)    # still <file.jpg>
            api POST "/api/sensors/still?deviceId=$DEV" \
              -H 'Content-Type: image/jpeg' --data-binary "@${2:?need a jpeg path}"; echo ;;

  poll)     api GET "/api/sensors/commands?deviceId=$DEV"; echo ;;

  agent)    # The phone's real loop: announce, then long-poll forever and act.
            echo "registering $DEV -> $BASE"
            register; echo
            while true; do
              out=$(api GET "/api/sensors/commands?deviceId=$DEV")
              echo "$(date +%T) <- $out"
              case "$out" in
                *mic.start*)
                  jpost POST /api/sensors/transcript \
                    "{\"deviceId\":\"$DEV\",\"text\":\"listening\",\"final\":false}" >/dev/null
                  jpost POST /api/sensors/transcript \
                    "{\"deviceId\":\"$DEV\",\"text\":\"open the ortho repo\",\"final\":true}" >/dev/null
                  echo "   -> pushed a transcript" ;;
                *camera.still*)
                  # 1x1 jpeg, enough to prove the byte path
                  printf '\xff\xd8\xff\xdb\x00C\x00\xff\xd9' > /tmp/fake-still.jpg
                  api POST "/api/sensors/still?deviceId=$DEV" \
                    -H 'Content-Type: image/jpeg' --data-binary @/tmp/fake-still.jpg >/dev/null
                  echo "   -> pushed a still" ;;
              esac
              register >/dev/null   # heartbeat
            done ;;

  *) sed -n '2,12p' "$0" ;;
esac
