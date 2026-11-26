#!/usr/bin/env bash
# Register every schemas/<subject>.avsc in Schema Registry (runs inside the init container).
#   - subject name = file name, e.g. transactions-value.avsc -> subject `transactions-value`
#   - Datagen hints (`arg.properties`) are stripped so the registry holds the clean contract
#   - compatibility is pinned per subject (BACKWARD) before registering
# Registering an identical schema again is a no-op (same id/version). An incompatible change fails with 409.
set -euo pipefail
SR_URL="${SCHEMA_REGISTRY_URL:-http://schema-registry:8081}"
SCHEMAS_DIR="${SCHEMAS_DIR:-/etc/schemas}"
COMPAT="${SCHEMA_COMPATIBILITY:-BACKWARD}"

echo "Waiting for Schema Registry at $SR_URL ..."
until curl -sf "$SR_URL/subjects" >/dev/null; do sleep 2; done

for f in "$SCHEMAS_DIR"/*.avsc; do
  subject="$(basename "$f" .avsc)"
  clean="$(jq -c 'walk(if type == "object" then del(."arg.properties") else . end)' "$f")"

  curl -sf -X PUT -H 'Content-Type: application/vnd.schemaregistry.v1+json' \
    --data "{\"compatibility\":\"$COMPAT\"}" "$SR_URL/config/$subject" >/dev/null

  body="$(jq -n --arg s "$clean" '{schemaType: "AVRO", schema: $s}')"
  resp="$(curl -s -w '\n%{http_code}' -X POST -H 'Content-Type: application/vnd.schemaregistry.v1+json' \
    --data "$body" "$SR_URL/subjects/$subject/versions")"
  code="${resp##*$'\n'}"; resp="${resp%$'\n'*}"
  if [ "$code" != 200 ]; then
    echo "!! $subject: HTTP $code $resp" >&2
    exit 1
  fi
  version="$(curl -sf "$SR_URL/subjects/$subject/versions/latest" | jq -r .version)"
  echo "-> $subject  id=$(echo "$resp" | jq -r .id)  version=$version  compatibility=$COMPAT"
done
