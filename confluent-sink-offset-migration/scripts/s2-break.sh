#!/usr/bin/env bash
# Scenario 2, break: the Snowflake-style sink keeps its offset token in the target. On the new
# cluster the topic starts again at offset 0, far below the token, so every record looks like a
# duplicate it already ingested.
. "$(dirname "$0")/lib.sh"
N=${N:-1000} M=${M:-300} K=${K:-50}

step "Cluster A era: the emulator loads $N records into orders_sf"
emulator_up a
produce a "$N"
wait_rows orders_sf "$N"
note "channel $SF_CHANNEL offset token: $(sql "SELECT offset_token FROM sf_channels WHERE channel_name = '$SF_CHANNEL'")"

step "Migration: the connector on cluster A is stopped"
emulator_down a

step "Producers cut over to cluster B (a new topic, offsets start at 0) and send $M records"
produce b "$M"

step "The connector is re-created on cluster B with the same name, so it opens the same channel"
emulator_up b
sleep 5

step "Traffic continues: $K more records to cluster B"
produce b "$K"
settle orders_sf

step "Result (run 'just s2-detect' for the full picture)"
scripts/gaps.sh orders_sf
