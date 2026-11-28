#!/usr/bin/env bash
# gaps.sh [--strict] [table...]: compare what was produced (seq 1..N) with what reached the tables.
# --strict exits 1 if any table has missing or duplicate seqs (the scenarios use this as their test).
. "$(dirname "$0")/lib.sh"

strict=0; [ "${1:-}" = --strict ] && { strict=1; shift; }
tables=("$@"); [ ${#tables[@]} -eq 0 ] && tables=(orders_jdbc orders_sf)
n=$(produced_total)
fail=0

for t in "${tables[@]}"; do
  read -r rows distinct dupes < <(sql "SELECT count(*), count(DISTINCT seq), count(*) - count(DISTINCT seq) FROM $t" | tr '|' ' ')
  missing=$(sql "SELECT count(*) FROM generate_series(1, $n) s(seq) WHERE NOT EXISTS (SELECT 1 FROM $t WHERE $t.seq = s.seq)")
  printf '    %-12s produced %-5s rows %-5s distinct %-5s missing %-5s duplicates %s\n' "$t" "$n" "$rows" "$distinct" "$missing" "$dupes"
  if [ "$missing" -gt 0 ]; then
    sql "WITH m AS (SELECT s.seq FROM generate_series(1, $n) s(seq)
                     WHERE NOT EXISTS (SELECT 1 FROM $t WHERE $t.seq = s.seq)),
              g AS (SELECT seq, seq - row_number() OVER (ORDER BY seq) AS grp FROM m)
         SELECT '      missing seq ' || min(seq) || '..' || max(seq) || ' (' || count(*) || ')'
           FROM g GROUP BY grp ORDER BY min(seq)"
    fail=1
  fi
  [ "$dupes" -gt 0 ] && fail=1
done

if [ $strict = 1 ]; then
  if [ $fail = 0 ]; then ok "every produced seq is in ${tables[*]} exactly once"; else bad "gaps or duplicates found"; exit 1; fi
fi
