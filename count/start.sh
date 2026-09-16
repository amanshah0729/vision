#!/usr/bin/env bash
# Start the card-count worker next to the bridge. Used by the com.vision.count LaunchAgent
# and fine by hand. Builds the venv on first run so a fresh checkout on the Air needs
# nothing but python3 (the system one is enough — 3.9 works).
#
#   count/start.sh              → worker against http://127.0.0.1:8791, token from ../.token
#   DECKS=8 count/start.sh
set -euo pipefail
cd "$(dirname "$0")"
if [ ! -x .venv/bin/python ]; then
  python3 -m venv .venv
  .venv/bin/pip install --quiet --upgrade pip
  .venv/bin/pip install --quiet -r requirements.txt
fi
exec .venv/bin/python worker.py "$@"
