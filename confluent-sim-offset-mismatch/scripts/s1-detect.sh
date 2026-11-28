#!/usr/bin/env bash
# Scenario 1, detect: everything looks healthy, except the data.
. "$(dirname "$0")/lib.sh"

step "Connector status on connect-b"
note "$JDBC: $(connector_state b)   <- RUNNING, no errors"

step "Consumer group $JDBC_GROUP on cluster B"
describe_group b "$JDBC_GROUP" | sed 's/^/    /'
note "LAG 0: by Kafka's measure the sink is fully caught up"

step "Target table: rows per source cluster"
scripts/count.sh

step "Gap check against what was produced"
scripts/gaps.sh orders_jdbc

step "Where the missing records are"
first_b=$(sql "SELECT min(seq) FROM orders_jdbc WHERE cluster = 'b'")
note "first seq from cluster B that reached Postgres: ${first_b:-none}"
note "earliest offset still on cluster B: $(kexec b kafka-get-offsets --topic "$TOPIC" --time -2)"
note "The missing records are still on cluster B; nothing has expired yet, so they can be replayed."
note "Fix: just s1-fix (offset at the last-loaded timestamp)  or  just s1-fix earliest"
