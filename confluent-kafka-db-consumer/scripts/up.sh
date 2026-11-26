#!/usr/bin/env bash
# Build the Connect image, start everything, wait for the connectors, then show rows in Postgres.
set -euo pipefail
cd "$(dirname "$0")/.."

docker compose up -d --build
echo "Waiting for connect-init to register the connectors..."
docker wait kafka-connect-init >/dev/null
docker logs kafka-connect-init

echo "Waiting for the first rows in Postgres..."
until docker exec postgres psql -U demo -d demo -tAc 'SELECT 1 FROM orders LIMIT 1' 2>/dev/null | grep -q 1; do sleep 2; done
scripts/query.sh

echo
echo "Kafka UI: http://localhost:8082   pgAdmin: http://localhost:5050   Connect REST: http://localhost:8083"
