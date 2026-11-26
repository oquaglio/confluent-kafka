#!/usr/bin/env bash
# Send one hand-written transaction to topic `transactions`, serialized with the LATEST registered schema.
# Usage: scripts/produce.sh [transaction_id] [amount] [status: PENDING|COMPLETED|FAILED]
# The JSON below is Avro's JSON encoding: a union value is wrapped in its branch type ({"string": "..."}).
# If you've evolved the schema with new fields, add them here too (or the producer rejects the record).
set -euo pipefail
ID="${1:-TX-MANUAL1}"; AMOUNT="${2:-42.5}"; STATUS="${3:-COMPLETED}"
NOW=$(( $(date +%s) * 1000 ))

SCHEMA_ID=$(curl -sf http://localhost:8081/subjects/transactions-value/versions/latest | sed -E 's/.*"id":([0-9]+).*/\1/')

RECORD="$ID|{\"transaction_id\":\"$ID\",\"account_id\":\"ACC-9999\",\"amount\":$AMOUNT,\"currency\":\"AUD\",\"status\":\"$STATUS\",\"created_at\":$NOW,\"note\":{\"string\":\"sent by produce.sh\"}}"

# -Dlog4j2.level=ERROR hides the console producer's INFO noise; errors still show.
echo "$RECORD" | docker exec -i -e SCHEMA_REGISTRY_LOG4J_OPTS=-Dlog4j2.level=ERROR schema-registry \
  kafka-avro-console-producer --bootstrap-server kafka:29092 --topic transactions \
  --property schema.registry.url=http://localhost:8081 \
  --property value.schema.id="$SCHEMA_ID" \
  --property parse.key=true --property key.separator='|' \
  --property key.serializer=org.apache.kafka.common.serialization.StringSerializer

echo "Sent $ID with schema id $SCHEMA_ID. Check with: scripts/query.sh \"SELECT * FROM transactions WHERE transaction_id='$ID'\""
