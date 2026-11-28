#!/usr/bin/env bash
# Scenario 2, fix.
#   Attempt 1 (wrong): reset the Kafka consumer group. The channel token still wins.
#   Attempt 2: set the channel offset token to -1 (Snowflake: SYSTEM$SNOWPIPE_STREAMING_UPDATE_CHANNEL_OFFSET_TOKEN)
#              so the Kafka offset is the source of truth, put the Kafka offset where the gap starts,
#              restart, then check for and remove duplicates.
. "$(dirname "$0")/lib.sh"
K=${K:-50}

rows_from_b() { sql "SELECT count(*) FROM orders_sf WHERE cluster = 'b'"; }

step "Attempt 1: reset consumer group $SF_GROUP on cluster B to earliest"
emulator_down b
kexec b kafka-consumer-groups --group "$SF_GROUP" --topic "$TOPIC" --reset-offsets --to-earliest --execute | sed 's/^/    /'
emulator_rm b; emulator_up b
sleep 8
note "rows from cluster B in orders_sf: $(rows_from_b)"
emulator_logs b | grep -E 'open channel|SKIPPED' | tail -n 3
bad "No change: on open the channel token ($(sql "SELECT offset_token FROM sf_channels WHERE channel_name = '$SF_CHANNEL'")) overrides the group offset"

step "Attempt 2.1: stop the connector, then set the channel offset token to -1"
emulator_down b
psql_c -c "SELECT sf_update_channel_offset_token('orders_sf', '$SF_CHANNEL', -1)"
note "Snowflake equivalent:"
note "  SELECT SYSTEM\$SNOWPIPE_STREAMING_UPDATE_CHANNEL_OFFSET_TOKEN('<db>.<schema>.ORDERS_SF', '$SF_CHANNEL', '-1');"

step "Attempt 2.2: point the Kafka offset at the first record after the last one that was loaded"
last_ts=$(sql "SELECT max(ts_ms) FROM orders_sf")
note "last loaded record has ts_ms $last_ts ($(date -u -d @"$((last_ts / 1000))" +%FT%TZ))"
while IFS=: read -r p o; do
  [ "$o" = -1 ] && o=$(end_offset b)   # nothing newer: start at the end
  note "partition $p -> offset $o"
  kexec b kafka-consumer-groups --group "$SF_GROUP" --topic "$TOPIC:$p" --reset-offsets --to-offset "$o" --execute >/dev/null
done < <(offsets_for_time b "$((last_ts + 1))")
describe_group b "$SF_GROUP" | sed 's/^/    /'
note "Confluent Cloud equivalent: POST .../connectors/<name>/offsets/request with {\"type\":\"PATCH\",...}"

step "Attempt 2.3: start the connector again"
emulator_rm b; emulator_up b
settle orders_sf
emulator_logs b | grep -E 'open channel|inserted' | head -n 3

step "Traffic continues: $K more records to cluster B"
produce b "$K"
settle orders_sf

step "Duplicates? (a replay that started too early would add them; orders_sf has no primary key)"
dupes=$(sql "SELECT count(*) - count(DISTINCT seq) FROM orders_sf")
if [ "$dupes" -gt 0 ]; then
  note "$dupes duplicate rows, removing them (keeping the first load of each seq)"
  scripts/dedupe.sh
else
  note "none"
fi

step "State after the fix"
note "channel token $(sql "SELECT offset_token FROM sf_channels WHERE channel_name = '$SF_CHANNEL'"), cluster B log-end offset $(end_offset b)"
scripts/count.sh
scripts/gaps.sh --strict orders_sf
