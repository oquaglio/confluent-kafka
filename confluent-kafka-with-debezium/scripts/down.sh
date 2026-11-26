#!/usr/bin/env bash
# Stop everything. Pass -v to also delete the Kafka and both Postgres volumes (start fresh next time).
set -euo pipefail
cd "$(dirname "$0")/.."
docker compose down "$@"
