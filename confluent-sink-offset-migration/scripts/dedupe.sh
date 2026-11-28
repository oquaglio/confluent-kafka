#!/usr/bin/env bash
# Remove duplicate seqs from orders_sf, keeping the earliest-loaded row of each.
# Snowflake has no ctid; there you would rebuild the table instead, e.g.
#   INSERT OVERWRITE INTO orders_sf
#   SELECT * FROM orders_sf QUALIFY ROW_NUMBER() OVER (PARTITION BY seq ORDER BY loaded_at) = 1;
. "$(dirname "$0")/lib.sh"
psql_c -c "DELETE FROM orders_sf t USING (
             SELECT ctid, row_number() OVER (PARTITION BY seq ORDER BY loaded_at, ctid) AS rn FROM orders_sf
           ) d
           WHERE t.ctid = d.ctid AND d.rn > 1"
