#!/usr/bin/env bash
# Send one hand-written order to the `orders` topic (Avro, same schema Datagen registered).
# Usage: scripts/produce.sh [orderid] [itemid] [orderunits]
set -euo pipefail
ID="${1:-999999}"; ITEM="${2:-Item_manual}"; UNITS="${3:-1.5}"
NOW=$(( $(date +%s) * 1000 ))

# Reuse the latest schema Datagen registered for orders-value.
SCHEMA_ID=$(curl -sf http://localhost:8081/subjects/orders-value/versions/latest | sed -E 's/.*"id":([0-9]+).*/\1/')

RECORD="$ID|{\"ordertime\":$NOW,\"orderid\":$ID,\"itemid\":\"$ITEM\",\"orderunits\":$UNITS,\"address\":{\"city\":\"Perth\",\"state\":\"WA\",\"zipcode\":6000}}"

# -Dlog4j2.level=ERROR hides the console producer's INFO noise; errors still show.
echo "$RECORD" | docker exec -i -e SCHEMA_REGISTRY_LOG4J_OPTS=-Dlog4j2.level=ERROR schema-registry \
  kafka-avro-console-producer --bootstrap-server kafka:29092 --topic orders \
  --property schema.registry.url=http://localhost:8081 \
  --property value.schema.id="$SCHEMA_ID" \
  --property parse.key=true --property key.separator='|' \
  --property key.serializer=org.apache.kafka.common.serialization.StringSerializer

echo "Sent order $ID. Check with: scripts/query.sh \"SELECT * FROM orders WHERE orderid=$ID\""
