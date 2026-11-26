#!/usr/bin/env bash
# Show the same table in the source and the sink database side by side.
# Usage: scripts/compare.sh [table]   (default: both customers and orders)
set -euo pipefail
TABLES="${1:-customers orders}"
for t in $TABLES; do
  echo "================ $t ================"
  echo "--- source-db (shop)"
  docker exec source-db psql -U demo -d shop -c "SELECT * FROM $t ORDER BY id"
  echo "--- sink-db (warehouse)"
  docker exec sink-db psql -U warehouse -d warehouse -c "SELECT * FROM $t ORDER BY id"
done
