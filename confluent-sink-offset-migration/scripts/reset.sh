#!/usr/bin/env bash
# Back to a clean slate without rebuilding: no connectors, emulators, groups or data; fresh topics.
. "$(dirname "$0")/lib.sh"

step "Resetting: connectors, emulators, consumer groups, topics, target tables"
emulator_rm a; emulator_rm b   # also clears their logs
delete_jdbc a; delete_jdbc b
for c in a b; do
  for g in "$JDBC_GROUP" "$SF_GROUP"; do
    # The group only becomes deletable once the connector's task has gone; retry briefly.
    for _ in $(seq 15); do
      out=$(kexec "$c" kafka-consumer-groups --delete --group "$g" 2>&1 || true)
      echo "$out" | grep -qE 'successful|does not exist|not exist' && break
      sleep 2
    done
  done
  kexec "$c" kafka-topics --delete --if-exists --topic "$TOPIC" >/dev/null 2>&1 || true
  for _ in $(seq 30); do
    kexec "$c" kafka-topics --create --if-not-exists --topic "$TOPIC" --partitions 1 --replication-factor 1 >/dev/null 2>&1 &&
      [ "$(end_offset "$c")" = 0 ] && break
    sleep 1
  done
  note "cluster $c: topic $TOPIC (1 partition) recreated, log-end offset $(end_offset "$c")"
done
sql "TRUNCATE orders_jdbc, orders_sf, sf_channels" >/dev/null
command rm -rf "$STATE"
note "orders_jdbc, orders_sf, sf_channels truncated; seq counter back to 1"
