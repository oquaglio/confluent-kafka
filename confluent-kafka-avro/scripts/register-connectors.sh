#!/usr/bin/env bash
# Create or update every connectors/<name>.json in Kafka Connect (runs inside the init container).
# PUT /connectors/<name>/config is idempotent: creates the connector or updates it in place.
# A string value "@file:<path>" is replaced by that file's content, so the Datagen connector reads its
# schema from schemas/ instead of holding a second copy of it.
set -euo pipefail
CONNECT_URL="${CONNECT_URL:-http://connect:8083}"
CONNECTORS_DIR="${CONNECTORS_DIR:-/etc/connectors}"

echo "Waiting for Kafka Connect at $CONNECT_URL ..."
until curl -sf "$CONNECT_URL/connectors" >/dev/null; do sleep 3; done

for f in "$CONNECTORS_DIR"/*.json; do
  name="$(basename "$f" .json)"
  config="$(cat "$f")"
  while ref="$(jq -r '[.. | strings | select(startswith("@file:"))][0] // empty' <<<"$config")" && [ -n "$ref" ]; do
    config="$(jq --arg ref "$ref" --rawfile content "${ref#@file:}" \
      'walk(if . == $ref then $content else . end)' <<<"$config")"
  done
  resp="$(curl -s -w '\n%{http_code}' -X PUT -H 'Content-Type: application/json' \
    --data "$config" "$CONNECT_URL/connectors/$name/config")"
  code="${resp##*$'\n'}"
  if [ "$code" != 200 ] && [ "$code" != 201 ]; then
    echo "!! $name: HTTP $code ${resp%$'\n'*}" >&2
    exit 1
  fi
  echo "-> $name ($([ "$code" = 201 ] && echo created || echo updated))"
done

sleep 5
for f in "$CONNECTORS_DIR"/*.json; do
  name="$(basename "$f" .json)"
  printf '   %-22s %s\n' "$name" \
    "$(curl -s "$CONNECT_URL/connectors/$name/status" | jq -r '[.connector.state] + [.tasks[].state] | join(" / ")')"
done
