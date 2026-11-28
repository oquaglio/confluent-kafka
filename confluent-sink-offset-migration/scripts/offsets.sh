#!/usr/bin/env bash
# Where everyone thinks they are: topic offsets, consumer groups on both clusters, Snowflake channels.
. "$(dirname "$0")/lib.sh"

for c in a b; do
  step "cluster $c: topic $TOPIC  (partition:log-start / log-end)"
  paste -d' ' <(kexec "$c" kafka-get-offsets --topic "$TOPIC" --time -2) <(kexec "$c" kafka-get-offsets --topic "$TOPIC" --time -1) |
    awk -F'[: ]' '{printf "    partition %s: log-start %s, log-end %s\n", $2, $3, $6}'
  for g in "$JDBC_GROUP" "$SF_GROUP"; do
    note "group $g:"
    describe_group "$c" "$g" | sed 's/^/      /'
  done
done
step "sf_channels (the emulated Snowflake SHOW CHANNELS)"
psql_c -c "SELECT table_name, channel_name, kafka_partition, offset_token, updated_at FROM sf_channels ORDER BY 1, 2"
