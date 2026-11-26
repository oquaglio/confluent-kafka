#!/usr/bin/env bash
# Rebuild the init image with your current schemas/ and connectors/ and run it again
# (what `docker compose watch` does automatically on every edit). Exits non-zero if init fails.
set -euo pipefail
cd "$(dirname "$0")/.."
docker compose up -d --build init
code="$(docker wait avro-init)"
docker logs avro-init
exit "$code"
