#!/usr/bin/env bash
# Move the pipeline to another schema version: copy evolution/<step>.avsc over
# schemas/transactions-value.avsc and re-run init, which
#   1. registers it in Schema Registry (refused with 409 if not BACKWARD compatible), then
#   2. updates the Datagen connector, so generated data uses the new version.
# The JDBC sink notices the new schema on the next record and ALTERs the table (auto.evolve).
# If registration is refused, the previous schema file is put back and nothing else changes.
#
# Usage: scripts/evolve.sh v2 | v3 | v4-breaking | v1
# Don't run it while `docker compose watch` is running: watch would also re-run init on the copy.
set -euo pipefail
cd "$(dirname "$0")/.."
STEP="${1:?usage: scripts/evolve.sh <step>  (steps: $(ls evolution/*.avsc | xargs -n1 basename | sed 's/\.avsc$//' | tr '\n' ' '))}"
SRC="evolution/$STEP.avsc"
DST="schemas/transactions-value.avsc"
[ -f "$SRC" ] || { echo "no such step: $SRC" >&2; exit 2; }

BACKUP="$(mktemp)"; trap 'rm -f "$BACKUP"' EXIT
cp -f "$DST" "$BACKUP"
cp -f "$SRC" "$DST"

echo "== evolving to $STEP"
code=0
scripts/reinit.sh >"$BACKUP.log" 2>&1 || code=$?
grep -vE '^ *(Container|Image) |^#|^$' "$BACKUP.log" || true
rm -f "$BACKUP.log"
if [ "$code" != 0 ]; then
  echo "== $STEP REFUSED by Schema Registry; restoring the previous $DST (pipeline unchanged)"
  cp -f "$BACKUP" "$DST"
  docker compose build -q init    # so a later `up` / watch doesn't bake in the refused file
  exit 1
fi
echo "== now on: $(curl -sf http://localhost:8081/subjects/transactions-value/versions/latest | jq -c '{version, id}')"
