#!/usr/bin/env bash
# Print the raw Debezium change events on a CDC topic (Ctrl+C to stop).
# Usage: scripts/watch-topic.sh [customers|orders]
set -euo pipefail
TOPIC="cdc.public.${1:-orders}"
docker exec -it -e SCHEMA_REGISTRY_LOG4J_OPTS=-Dlog4j2.level=ERROR schema-registry \
  kafka-avro-console-consumer --bootstrap-server kafka:29092 --topic "$TOPIC" --from-beginning \
  --property schema.registry.url=http://localhost:8081 --property print.key=true
