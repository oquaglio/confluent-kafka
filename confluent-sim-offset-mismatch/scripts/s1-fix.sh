#!/usr/bin/env bash
# Scenario 1, fix: stop the connector, move its consumer offsets back, resume.
#   s1-fix.sh datetime  (default) - Connect REST API (KIP-875): offset of the first record after the
#                                   last row that reached the target. Replays only the gap.
#   s1-fix.sh earliest            - kafka-consumer-groups --reset-offsets --to-earliest. Replays all
#                                   of cluster B; harmless here because the sink upserts on seq.
. "$(dirname "$0")/lib.sh"
mode=${1:-datetime}
url=$(connect_url b)

step "Stop the connector so its offsets can be changed (tasks shut down; config is kept)"
stop_jdbc b

case "$mode" in
  datetime)
    last_ts=$(sql "SELECT max(ts_ms) FROM orders_jdbc WHERE cluster = 'a'")
    note "last record loaded from the old cluster has ts_ms $last_ts ($(date -u -d @"$((last_ts / 1000))" +%FT%TZ))"
    step "Look up the first offset on cluster B after that timestamp (kafka-get-offsets --time)"
    body=$(offsets_for_time b "$((last_ts + 1))" | jq -Rn --arg t "$TOPIC" \
      '{offsets: [inputs | split(":") | {partition: {kafka_topic: $t, kafka_partition: (.[0] | tonumber)},
                                         offset: {kafka_offset: (.[1] | tonumber)}}]}')
    echo "$body" | jq -c '.offsets[]' | sed 's/^/    /'
    step "Current connector offsets (GET /connectors/$JDBC/offsets)"
    curl -s "$url/connectors/$JDBC/offsets" | jq -c '.offsets[]' | sed 's/^/    /'
    step "PATCH /connectors/$JDBC/offsets"
    curl -sf -X PATCH -H 'Content-Type: application/json' --data "$body" "$url/connectors/$JDBC/offsets" | jq -r .message | sed 's/^/    /'
    ;;
  earliest)
    step "kafka-consumer-groups --reset-offsets --to-earliest on cluster B (dry run, then execute)"
    kexec b kafka-consumer-groups --group "$JDBC_GROUP" --topic "$TOPIC" --reset-offsets --to-earliest --dry-run | sed 's/^/    /'
    kexec b kafka-consumer-groups --group "$JDBC_GROUP" --topic "$TOPIC" --reset-offsets --to-earliest --execute >/dev/null
    ;;
  *) echo "usage: $0 [datetime|earliest]" >&2; exit 2 ;;
esac

step "Resume and let it replay"
resume_jdbc b
settle orders_jdbc
describe_group b "$JDBC_GROUP" | sed 's/^/    /'

step "Gap check"
scripts/count.sh
scripts/gaps.sh --strict orders_jdbc
