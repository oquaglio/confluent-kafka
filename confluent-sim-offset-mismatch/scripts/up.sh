#!/usr/bin/env bash
# Build images, start both clusters, both Connect workers, Postgres and Kafka UI, create `orders`.
. "$(dirname "$0")/lib.sh"

step "Starting the stack (emulators are started later by the scenarios)"
docker compose --profile emulator build
docker compose up -d --wait
scripts/reset.sh
echo
note "Kafka UI: http://localhost:8080   connect-a: http://localhost:8083   connect-b: http://localhost:8084"
note "Next: just s1   or   just s2"
