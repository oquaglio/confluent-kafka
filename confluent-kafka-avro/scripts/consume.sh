#!/usr/bin/env bash
# Print records from topic `transactions`, Avro-decoded back to JSON via Schema Registry.
# Usage: scripts/consume.sh [count]   (default 5, from the beginning)
set -euo pipefail
N="${1:-5}"
docker exec -e SCHEMA_REGISTRY_LOG4J_OPTS=-Dlog4j2.level=ERROR schema-registry \
  kafka-avro-console-consumer --bootstrap-server kafka:29092 --topic transactions \
  --from-beginning --max-messages "$N" \
  --property schema.registry.url=http://localhost:8081 \
  --property print.key=true --property print.schema.ids=true \
  --property key.deserializer=org.apache.kafka.common.serialization.StringDeserializer
