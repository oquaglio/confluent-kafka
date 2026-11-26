#!/usr/bin/env bash
# Create or update every connector in a directory of <name>.json files (PUT is idempotent).
#
# Runs in two places:
#   - inside the connect-init container on `docker compose up` (defaults below)
#   - from the host:  scripts/register-connectors.sh   (uses ./connectors and localhost:8083)
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
if [ -d /etc/connectors ]; then DEFAULT_DIR=/etc/connectors; else DEFAULT_DIR="$HERE/../connectors"; fi
CONNECT_URL="${CONNECT_URL:-http://localhost:8083}"
CONNECTORS_DIR="${CONNECTORS_DIR:-$DEFAULT_DIR}"

echo "Waiting for Kafka Connect at $CONNECT_URL ..."
until curl -sf "$CONNECT_URL/connectors" >/dev/null; do sleep 3; done

for f in "$CONNECTORS_DIR"/*.json; do
  name="$(basename "$f" .json)"
  echo "-> $name"
  curl -sf -X PUT -H 'Content-Type: application/json' \
    --data @"$f" "$CONNECT_URL/connectors/$name/config" >/dev/null
done

sleep 3
for f in "$CONNECTORS_DIR"/*.json; do
  name="$(basename "$f" .json)"
  printf '%-20s ' "$name"
  curl -s "$CONNECT_URL/connectors/$name/status" | tr -d '\n' | sed -E 's/.*"connector":\{"state":"([A-Z]+)".*/\1/'
  echo
done
