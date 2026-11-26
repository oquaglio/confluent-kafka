#!/usr/bin/env bash
# Make an INSERT, an UPDATE and a DELETE in the source database so you can watch them flow to the sink.
set -euo pipefail
N=$RANDOM
docker exec -i source-db psql -U demo -d shop -v ON_ERROR_STOP=1 <<SQL
-- INSERT: a new customer with one order
WITH c AS (
  INSERT INTO customers (first_name, last_name, email)
  VALUES ('Customer', '$N', 'customer$N@example.com') RETURNING id
)
INSERT INTO orders (customer_id, product, quantity, price)
SELECT id, 'Widget $N', 1 + $N % 5, round(($N % 10000) / 100.0, 2) FROM c;

-- UPDATE: move the oldest open order one status forward
UPDATE orders SET status = CASE status WHEN 'NEW' THEN 'PAID' ELSE 'SHIPPED' END, updated_at = now()
WHERE id = (SELECT min(id) FROM orders WHERE status <> 'SHIPPED');

-- DELETE: remove the oldest shipped order once there are more than 5 orders
DELETE FROM orders
WHERE id = (SELECT min(id) FROM orders WHERE status = 'SHIPPED') AND (SELECT count(*) FROM orders) > 5;
SQL
echo "Changes made in source-db. Give the pipeline a second, then: scripts/compare.sh"
