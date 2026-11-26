#!/usr/bin/env bash
# Run SQL (or open psql) on one of the databases.
# Usage: scripts/sql.sh source|sink ["SQL"]
set -euo pipefail
case "${1:-}" in
  source) C=source-db U=demo      D=shop ;;
  sink)   C=sink-db   U=warehouse D=warehouse ;;
  *) echo "usage: $0 source|sink [\"SQL\"]" >&2; exit 1 ;;
esac
if [ -n "${2:-}" ]; then docker exec "$C" psql -U "$U" -d "$D" -c "$2"
else docker exec -it "$C" psql -U "$U" -d "$D"; fi
