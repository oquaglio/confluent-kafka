#!/usr/bin/env bash
# Scenario 2, detect: the connector runs and nothing arrives. The tell is the offset token sitting
# above the new cluster's log-end offset.
. "$(dirname "$0")/lib.sh"

step "Emulator on cluster B: running?"
note "sf-emulator-b: $(docker inspect -f '{{.State.Status}}' sf-emulator-b)   <- no crash, no error"

step "Target table: rows per source cluster"
scripts/count.sh

step "Gap check"
scripts/gaps.sh orders_sf

step "The mismatch: channel offset token vs cluster B's topic"
token=$(sql "SELECT offset_token FROM sf_channels WHERE channel_name = '$SF_CHANNEL'")
leo=$(end_offset b)
note "channel $SF_CHANNEL offset token: $token"
note "cluster B $TOPIC log-end offset:   $leo"
if [ "$token" -ge "$leo" ]; then
  bad "token $token >= log-end offset $leo: every record on cluster B counts as already ingested"
  bad "and this continues until cluster B passes offset $token, $((token - leo + 1)) records from now"
fi

step "Consumer group $SF_GROUP on cluster B"
describe_group b "$SF_GROUP" | sed 's/^/    /'
note "The committed offset is the token + 1, which is past the log end: LAG is negative. Kafka UI"
note "and most lag alerts only look for positive lag, so this goes unnoticed."

step "Emulator log on cluster B"
emulator_logs b
note "Fix: just s2-fix"
