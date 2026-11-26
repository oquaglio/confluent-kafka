#!/usr/bin/env bash
# Act as an application that was built against ONE schema version and send one record with it.
# Like a real producer with auto.register.schemas=false, it only works if that exact schema is already
# registered: otherwise the serializer fails with "Schema not found; error code: 40403".
# Lets you run "old" and "new" producers side by side on the same topic (and table).
#
# Usage: scripts/produce-as.sh v1|v2|v3 [transaction_id]     (needs jq on the host)
set -euo pipefail
cd "$(dirname "$0")/.."
V="${1:?usage: scripts/produce-as.sh v1|v2|v3 [transaction_id]}"
ID="${2:-TX-APP-$V-$RANDOM}"
NOW=$(( $(date +%s) * 1000 ))
[ -f "evolution/$V.avsc" ] || { echo "no such schema: evolution/$V.avsc" >&2; exit 2; }

# The schema as registered (Datagen hints stripped).
SCHEMA="$(jq -c 'walk(if type == "object" then del(."arg.properties") else . end)' "evolution/$V.avsc")"

# A record matching that version, in Avro JSON encoding (a union value is wrapped: {"string": "..."}).
BASE="\"transaction_id\":\"$ID\",\"account_id\":\"ACC-$V\",\"amount\":10.0,\"currency\":\"AUD\",\"status\":\"COMPLETED\",\"created_at\":$NOW"
case "$V" in
  v1) VALUE="{$BASE,\"note\":{\"string\":\"from a $V app\"}}" ;;
  v2) VALUE="{$BASE,\"note\":{\"string\":\"from a $V app\"},\"channel\":\"mobile\"}" ;;
  v3) VALUE="{$BASE,\"channel\":\"pos\",\"fee\":0.35}" ;;
  *)  echo "no sample record for $V" >&2; exit 2 ;;
esac

if out="$(echo "$ID|$VALUE" | docker exec -i -e SCHEMA_REGISTRY_LOG4J_OPTS=-Dlog4j2.level=ERROR schema-registry \
    kafka-avro-console-producer --bootstrap-server kafka:29092 --topic transactions \
    --property schema.registry.url=http://localhost:8081 \
    --property value.schema="$SCHEMA" \
    --property auto.register.schemas=false \
    --property parse.key=true --property key.separator='|' \
    --property key.serializer=org.apache.kafka.common.serialization.StringSerializer 2>&1)" \
   && ! grep -q Exception <<<"$out"; then
  echo "sent $ID as $V"
else
  reason="$(grep -m1 -oE 'Schema not found; error code: [0-9]+' <<<"$out" || grep -m1 -E 'Caused by|Exception' <<<"$out" || true)"
  echo "REFUSED: $V app can't send $ID: $reason" >&2
  exit 1
fi
