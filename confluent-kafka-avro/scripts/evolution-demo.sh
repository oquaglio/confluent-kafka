#!/usr/bin/env bash
# Walk through schema evolution end to end on ONE topic and ONE table.
# Needs a fresh stack at schema v1 (run scripts/reset.sh first; it wipes all data).
# Pass -y to skip the "press Enter" pauses.
set -euo pipefail
cd "$(dirname "$0")/.."
PAUSE=1; [ "${1:-}" = "-y" ] && PAUSE=0

step() { echo; echo "────────────────────────────────────────────────────────────────"; echo "▶ $*"; \
         if [ "$PAUSE" = 1 ]; then read -rp "  (Enter to continue) " _; fi; }
columns() { docker exec postgres psql -U demo -d demo -tAc \
  "SELECT string_agg(column_name || ' ' || data_type || coalesce(' DEFAULT ' || column_default, ''), ', ' ORDER BY ordinal_position)
     FROM information_schema.columns WHERE table_name = 'transactions'" | sed 's/^/  table: /'; }
rows() { docker exec postgres psql -U demo -d demo -c \
  "SELECT transaction_id, account_id, note, channel, fee FROM transactions WHERE transaction_id IN ($1) ORDER BY 1" 2>/dev/null \
  || docker exec postgres psql -U demo -d demo -c \
  "SELECT transaction_id, account_id, note, channel FROM transactions WHERE transaction_id IN ($1) ORDER BY 1"; }
wait_rows() { sleep 5; }

versions="$(curl -sf http://localhost:8081/subjects/transactions-value/versions || echo none)"
if [ "$versions" != "[1]" ]; then
  echo "Expected a fresh stack with only schema v1 registered (found: $versions)."
  echo "Run scripts/reset.sh first (deletes all data), then run this again."
  exit 1
fi

step "1. Start: schema v1, Datagen producing v1 records"
columns

step "2. A 'v2 app' is deployed before its schema is registered: it is refused"
scripts/produce-as.sh v2 TX-DEMO-V2-EARLY || true

step "3. Register v2 (adds 'channel' with default \"web\"); Datagen switches to v2"
scripts/evolve.sh v2
wait_rows
columns
echo "  -> the sink added the column itself (auto.evolve), with the Avro default as the column DEFAULT"

step "4. Old and new apps write to the same topic + table side by side"
scripts/produce-as.sh v1 TX-DEMO-V1
scripts/produce-as.sh v2 TX-DEMO-V2
wait_rows
rows "'TX-DEMO-V1','TX-DEMO-V2'"
echo "  -> the v1 record has no channel: Postgres fills in the column DEFAULT 'web'"

step "5. Register v3 (removes 'note', adds 'fee' default 0.0)"
scripts/evolve.sh v3
scripts/produce-as.sh v3 TX-DEMO-V3
scripts/produce-as.sh v1 TX-DEMO-V1-LATE
wait_rows
columns
rows "'TX-DEMO-V1-LATE','TX-DEMO-V3'"
echo "  -> 'note' is NOT dropped (the sink never drops/renames/retypes columns); v3 rows leave it NULL"

step "6. Try v4-breaking ('amount' double -> string): refused, nothing changes"
scripts/evolve.sh v4-breaking || true

step "Result"
echo "  registered versions: $(curl -sf http://localhost:8081/subjects/transactions-value/versions)"
curl -sf 'http://localhost:8083/connectors?expand=status' \
  | jq -r 'to_entries[] | "  \(.key): \(.value.status.connector.state) / \([.value.status.tasks[].state] | join(","))"'
docker exec postgres psql -U demo -d demo -c \
  "SELECT count(*) AS rows, count(note) AS with_note, count(*) FILTER (WHERE channel <> 'web') AS non_default_channel, count(*) FILTER (WHERE fee > 0) AS with_fee FROM transactions"
echo "Back to the start: scripts/reset.sh"
