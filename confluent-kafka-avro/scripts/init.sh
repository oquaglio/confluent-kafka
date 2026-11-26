#!/usr/bin/env bash
# Entry point of the `init` container: schemas first (the source connector refuses to auto-register),
# then connectors.
set -euo pipefail
/usr/local/bin/register-schemas.sh
/usr/local/bin/register-connectors.sh
echo "init done"
