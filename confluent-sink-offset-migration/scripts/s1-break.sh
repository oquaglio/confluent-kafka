#!/usr/bin/env bash
# Scenario 1, break: the JDBC sink is re-created on the new cluster, where its consumer group has no
# committed offsets, and auto.offset.reset=latest makes it start at the end of the topic.
. "$(dirname "$0")/lib.sh"
N=${N:-500} M=${M:-200} K=${K:-50}

step "Cluster A era: JDBC sink on connect-a loads $N records into orders_jdbc"
create_jdbc a earliest
produce a "$N"
wait_rows orders_jdbc "$N"

step "Migration: the connector is deleted on cluster A"
stop_jdbc a
delete_jdbc a
note "its consumer group connect-$JDBC (committed offset $N) stays behind on cluster A"

step "Producers cut over to cluster B first and send $M records; no sink is running on B yet"
produce b "$M"

step "The connector is re-created on connect-b with auto.offset.reset=latest"
create_jdbc b latest
wait_jdbc_assigned b
note "group $JDBC_GROUP on cluster B is new, so the task started at the log-end offset ($M)"

step "Traffic continues: $K more records to cluster B"
produce b "$K"
settle orders_jdbc

step "Result (run 'just s1-detect' for the full picture)"
scripts/gaps.sh orders_jdbc
