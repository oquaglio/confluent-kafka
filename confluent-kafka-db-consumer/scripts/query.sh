#!/usr/bin/env bash
# Show the latest rows the sink wrote. Optional arg: any SQL to run instead.
set -euo pipefail
SQL="${1:-SELECT * FROM orders ORDER BY orderid DESC LIMIT 10}"
docker exec postgres psql -U demo -d demo -c "SELECT count(*) AS total_rows FROM orders" -c "$SQL"
