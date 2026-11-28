#!/usr/bin/env bash
# Shared helpers, sourced by the other scripts. Everything goes through `docker exec` and curl, so
# the host only needs docker, curl, jq and envsubst.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

[ -f .env ] || cp .env.example .env
set -a; . ./.env; set +a

TOPIC=orders
JDBC=orders-jdbc              # connector name -> consumer group connect-orders-jdbc
JDBC_GROUP=connect-$JDBC
SF_GROUP=connect-orders-sf    # the emulator's consumer group
SF_CHANNEL=ORDERS_SF_ORDERS_0 # the emulator's channel for partition 0
STATE=.state                  # producer seq counter (gitignored)

# --- output -------------------------------------------------------------------------------------
step() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
note() { printf '    %s\n' "$*"; }
ok()   { printf '\033[1;32m    OK: %s\033[0m\n' "$*"; }
bad()  { printf '\033[1;31m    !! %s\033[0m\n' "$*"; }

# --- per-cluster wrappers: first arg is a | b ---------------------------------------------------
kexec()       { local c=$1 cmd=$2; shift 2; docker exec "kafka-$c" "$cmd" --bootstrap-server "kafka-$c:29092" "$@"; }
connect_url() { if [ "$1" = a ]; then echo http://localhost:8083; else echo http://localhost:8084; fi; }
psql_c()      { docker exec postgres psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v ON_ERROR_STOP=1 "$@"; }
sql()         { psql_c -tAc "$1"; }

# Log-end offset of the topic, summed over partitions.
end_offset() { kexec "$1" kafka-get-offsets --topic "$TOPIC" --time -1 | awk -F: '{s+=$3} END {print s+0}'; }

# "partition:offset" lines for the first record at or after a timestamp (epoch ms).
offsets_for_time() { kexec "$1" kafka-get-offsets --topic "$TOPIC" --time "$2" | awk -F: '{print $2":"$3}'; }

# Consumer group table, without the noise.
describe_group() {
  local out
  out=$(kexec "$1" kafka-consumer-groups --describe --group "$2" 2>&1 || true)
  if echo "$out" | grep -q GroupIdNotFoundException; then echo "(group $2 does not exist on cluster $1)"; return; fi
  echo "$out" | grep -v -e '^$' -e 'has no active members'
}

# --- producer -----------------------------------------------------------------------------------
# produce <cluster> <n>: n JSON records (Connect schema envelope) with a global, gap-free seq.
produce() {
  local c=$1 n=$2 start now
  mkdir -p "$STATE"
  start=$(cat "$STATE/next-seq" 2>/dev/null || echo 1)
  now=$(date +%s%3N)
  local schema='{"type":"struct","name":"order","optional":false,"fields":[{"field":"seq","type":"int64"},{"field":"ts_ms","type":"int64"},{"field":"cluster","type":"string"}]}'
  for ((i = 0; i < n; i++)); do
    local s=$((start + i))
    printf '%d|{"schema":%s,"payload":{"seq":%d,"ts_ms":%d,"cluster":"%s"}}\n' "$s" "$schema" "$s" "$((now + i))" "$c"
  done | docker exec -i "kafka-$c" kafka-console-producer --bootstrap-server "kafka-$c:29092" \
           --topic "$TOPIC" --property parse.key=true --property key.separator='|' \
           --producer-property linger.ms=20 >/dev/null
  echo $((start + n)) >"$STATE/next-seq"
  note "produced seq $start..$((start + n - 1)) to cluster $c (log-end offset on $c now $(end_offset "$c"))"
}

produced_total() { echo $(( $(cat "$STATE/next-seq" 2>/dev/null || echo 1) - 1 )); }

# --- JDBC connector -----------------------------------------------------------------------------
# create_jdbc <cluster> <auto.offset.reset>
create_jdbc() {
  AUTO_OFFSET_RESET=$2 envsubst '${AUTO_OFFSET_RESET}' <connectors/orders-jdbc.json |
    curl -sf -X PUT -H 'Content-Type: application/json' --data @- \
      "$(connect_url "$1")/connectors/$JDBC/config" >/dev/null
  wait_connector "$1" RUNNING
}

connector_state() {
  curl -s "$(connect_url "$1")/connectors/$JDBC/status" |
    jq -r '[.connector.state] + [.tasks[]?.state] | join("/")' 2>/dev/null || echo MISSING
}

wait_connector() {  # wait_connector <cluster> RUNNING|STOPPED
  local want=$2 s
  [ "$want" = RUNNING ] && want=RUNNING/RUNNING
  for _ in $(seq 60); do
    s=$(connector_state "$1")
    [ "$s" = "$want" ] && { note "$JDBC on connect-$1: $s"; return; }
    sleep 2
  done
  bad "$JDBC on connect-$1 never reached $2 (last: $s)"; return 1
}

stop_jdbc()   { curl -sf -X PUT "$(connect_url "$1")/connectors/$JDBC/stop" >/dev/null; wait_connector "$1" STOPPED; }
resume_jdbc() { curl -sf -X PUT "$(connect_url "$1")/connectors/$JDBC/resume" >/dev/null; wait_connector "$1" RUNNING; }
delete_jdbc() { curl -s -o /dev/null -X DELETE "$(connect_url "$1")/connectors/$JDBC" || true; }

# Wait until the JDBC task has partitions assigned (its consumer position is then fixed).
wait_jdbc_assigned() {
  for _ in $(seq 30); do
    kexec "$1" kafka-consumer-groups --describe --group "$JDBC_GROUP" --members 2>/dev/null |
      awk '$NF ~ /^[1-9]/ {found=1} END {exit !found}' && { sleep 3; return; }
    sleep 2
  done
  bad "$JDBC task never got partitions on cluster $1"; return 1
}

# --- emulator -----------------------------------------------------------------------------------
emulator_up()   { docker compose --profile emulator up -d --no-deps "sf-emulator-$1" >/dev/null 2>&1; note "started sf-emulator-$1"; }
emulator_down() { docker compose --profile emulator stop "sf-emulator-$1" >/dev/null 2>&1 || true; }
emulator_rm()   { docker compose --profile emulator rm -sf "sf-emulator-$1" >/dev/null 2>&1 || true; }
emulator_logs() { docker logs "sf-emulator-$1" 2>&1 | sed "s/^/      /"; }

# --- waiting ------------------------------------------------------------------------------------
# settle <table>: wait until the row count stops changing (the sink has caught up, or given up).
settle() {
  local prev=-1 same=0 cur=0
  for _ in $(seq 60); do
    cur=$(sql "SELECT count(*) FROM $1")
    if [ "$cur" = "$prev" ]; then same=$((same + 1)); else same=0; fi
    [ $same -ge 3 ] && { note "$1 settled at $cur rows"; return; }
    prev=$cur; sleep 2
  done
  note "$1 still changing ($cur rows), carrying on"
}

# wait_rows <table> <n>: wait until the table has at least n rows.
wait_rows() {
  for _ in $(seq 60); do
    [ "$(sql "SELECT count(*) FROM $1")" -ge "$2" ] && { note "$1 has $2 rows"; return; }
    sleep 2
  done
  bad "$1 never reached $2 rows"; return 1
}
