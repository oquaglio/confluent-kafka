#!/bin/sh
# Renders /src/*.txt into /www/index.html. The build counter proves the exec hook ran.
set -eu
count=$(( $(cat /www/.builds 2>/dev/null || echo 0) + 1 ))
echo "$count" > /www/.builds
{
  echo "<!doctype html><html><head><meta charset=utf-8><title>notes</title></head><body>"
  echo "<h1>Notes</h1><p id=build>build #$count at $(date -u +%H:%M:%S)</p>"
  for f in /src/*.txt; do
    [ -e "$f" ] || continue
    echo "<h2>$(basename "$f" .txt)</h2><pre>"
    sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g' "$f"
    echo "</pre>"
  done
  echo "</body></html>"
} > /www/index.html.tmp
mv /www/index.html.tmp /www/index.html
echo "build-notes: build #$count ($(ls /src/*.txt 2>/dev/null | wc -l) notes)"
