#!/usr/bin/env bash
# Start over at schema v1: put evolution/v1.avsc back in schemas/, delete all data (Kafka topics,
# registered schemas, Postgres table) and bring the stack up again.
set -euo pipefail
cd "$(dirname "$0")/.."
cp -f evolution/v1.avsc schemas/transactions-value.avsc
docker compose down -v
scripts/up.sh
