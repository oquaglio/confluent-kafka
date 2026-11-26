#!/usr/bin/env bash
# Ask Schema Registry whether the schema files would be accepted, WITHOUT registering them.
# Runs in the init image (has jq), rebuilt so it sees your current edits in schemas/.
# Usage: scripts/check-compat.sh
set -euo pipefail
cd "$(dirname "$0")/.."
docker compose build -q init
docker compose run --rm --no-deps -T --entrypoint bash init -c '
  for f in /etc/schemas/*.avsc; do
    subject="$(basename "$f" .avsc)"
    clean="$(jq -c "walk(if type == \"object\" then del(.\"arg.properties\") else . end)" "$f")"
    body="$(jq -n --arg s "$clean" "{schemaType: \"AVRO\", schema: \$s}")"
    resp="$(curl -s -X POST -H "Content-Type: application/vnd.schemaregistry.v1+json" --data "$body" \
      "$SCHEMA_REGISTRY_URL/compatibility/subjects/$subject/versions/latest?verbose=true")"
    if echo "$resp" | jq -e ".is_compatible" >/dev/null 2>&1; then
      echo "OK    $subject is compatible with the latest registered version"
    else
      echo "FAIL  $subject"; echo "$resp" | jq . 2>/dev/null || echo "$resp"
    fi
  done'
