#!/usr/bin/env bash
# Build the images, start everything, wait for the connectors, then compare source and sink.
set -euo pipefail
cd "$(dirname "$0")/.."

docker compose up -d --build
echo "Waiting for connect-init to register the connectors..."
docker wait kafka-connect-init >/dev/null
docker logs kafka-connect-init

echo "Waiting for the snapshot to reach the sink database..."
until docker exec sink-db psql -U warehouse -d warehouse -tAc 'SELECT 1 FROM orders LIMIT 1' 2>/dev/null | grep -q 1; do sleep 2; done
scripts/compare.sh

echo
echo "Kafka UI: http://localhost:8082   pgAdmin: http://localhost:5050   Connect REST: http://localhost:8083"
echo "Try:  scripts/change.sh   then   scripts/compare.sh"
