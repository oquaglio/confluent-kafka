#!/usr/bin/env bash
# Show containers, connector/task state, the replication slot and row counts on both sides.
set -euo pipefail
cd "$(dirname "$0")/.."

docker compose ps -a
echo
for c in $(curl -sf http://localhost:8083/connectors | tr -d '[]"' | tr ',' ' '); do
  echo "== $c"
  curl -sf "http://localhost:8083/connectors/$c/status"; echo
done
echo
echo "== replication slot in source-db"
docker exec source-db psql -U demo -d shop -c \
  "SELECT slot_name, plugin, active, confirmed_flush_lsn, pg_current_wal_lsn() AS current_lsn FROM pg_replication_slots"
echo "== row counts"
for t in customers orders; do
  s=$(docker exec source-db psql -U demo -d shop -tAc "SELECT count(*) FROM $t")
  k=$(docker exec sink-db psql -U warehouse -d warehouse -tAc "SELECT count(*) FROM $t" 2>/dev/null || echo "-")
  printf '%-10s source=%-5s sink=%s\n' "$t" "$s" "$k"
done
