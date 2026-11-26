#!/usr/bin/env bash
# Containers, registered schema versions, connector/task state and the row count in Postgres.
set -euo pipefail
cd "$(dirname "$0")/.."

docker compose ps -a
echo
echo "== Schema Registry subjects / versions"
for s in $(curl -sf http://localhost:8081/subjects | tr -d '[]"' | tr ',' ' '); do
  echo "$s: versions $(curl -sf "http://localhost:8081/subjects/$s/versions")"
done
echo
for c in $(curl -sf http://localhost:8083/connectors | tr -d '[]"' | tr ',' ' '); do
  echo "== connector $c"
  curl -sf "http://localhost:8083/connectors/$c/status"; echo
done
echo
docker exec postgres psql -U demo -d demo -c 'SELECT count(*) AS rows_in_transactions FROM transactions'
