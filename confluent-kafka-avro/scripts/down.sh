#!/usr/bin/env bash
# Stop everything. Pass -v to also delete the Kafka (incl. registered schemas) and Postgres volumes.
set -euo pipefail
cd "$(dirname "$0")/.."
docker compose down "$@"
