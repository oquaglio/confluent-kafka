#!/usr/bin/env bash
# Build the images, start everything, wait for init (schemas + connectors), then show rows in Postgres.
set -euo pipefail
cd "$(dirname "$0")/.."

docker compose up -d --build
echo "Waiting for init to register the schemas and connectors..."
code="$(docker wait avro-init)"
docker logs avro-init
[ "$code" = 0 ] || { echo "init failed (exit $code)" >&2; exit "$code"; }

echo "Waiting for the first rows in Postgres..."
until docker exec postgres psql -U demo -d demo -tAc 'SELECT 1 FROM transactions LIMIT 1' 2>/dev/null | grep -q 1; do sleep 2; done
scripts/query.sh

echo
echo "Kafka UI: http://localhost:8082   Schema Registry: http://localhost:8081   Connect REST: http://localhost:8083"
