#!/usr/bin/env bash
# Show containers, connector/task state and the row count in Postgres.
set -euo pipefail
cd "$(dirname "$0")/.."

docker compose ps -a
echo
for c in $(curl -sf http://localhost:8083/connectors | tr -d '[]"' | tr ',' ' '); do
  echo "== $c"
  curl -sf "http://localhost:8083/connectors/$c/status"; echo
done
echo
docker exec postgres psql -U demo -d demo -c 'SELECT count(*) AS rows_in_orders FROM orders'
