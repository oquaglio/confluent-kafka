#!/bin/sh
# Idempotent: keeps the first seed time across restarts, bumps the run count.
set -eu
out=/shared/stack-info.json
first=$(sed -n 's/.*"first_seeded": "\([^"]*\)".*/\1/p' "$out" 2>/dev/null || true)
runs=$(sed -n 's/.*"seed_runs": \([0-9]*\).*/\1/p' "$out" 2>/dev/null || true)
now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
cat > "$out.tmp" <<JSON
{"first_seeded": "${first:-$now}", "last_seeded": "$now", "seed_runs": $(( ${runs:-0} + 1 ))}
JSON
chmod 0644 "$out.tmp"
mv "$out.tmp" "$out"
echo "seeded $out: $(cat "$out")"
