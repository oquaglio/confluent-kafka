#!/usr/bin/env bash
# Rows per table and per source cluster.
. "$(dirname "$0")/lib.sh"
psql_c -c "SELECT 'orders_jdbc' AS tbl, cluster, count(*), min(seq), max(seq) FROM orders_jdbc GROUP BY cluster
           UNION ALL
           SELECT 'orders_sf', cluster, count(*), min(seq), max(seq) FROM orders_sf GROUP BY cluster
           ORDER BY 1, 2"
