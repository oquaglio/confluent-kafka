#!/usr/bin/env bash
# `check && ok … || fail …` is intentional: ok() never fails, fail() exits.
# shellcheck disable=SC2015
# Hands-free tour of every watch feature in this project.
# Starts the stack (detached), runs `docker compose watch --no-up` in the background,
# edits each watched file in turn, verifies the effect, then puts everything back.
set -euo pipefail
cd "$(dirname "$0")/.."

PORT="${GATEWAY_PORT:-8090}"
BASE="http://localhost:${PORT}"
WORK="$(mktemp -d)"
WATCH_LOG="$WORK/watch.log"
WATCH_PID=""
EDITED=(site/html/index.html gateway/nginx.conf api/app.py api/pyproject.toml)
CREATED=(site/html/drafts/wip.html site/html/notes.tmp site/html/new.html
         notes/content/03-demo.txt notes/content/scratch.md)

bold() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
ok()   { printf '   \033[32mOK\033[0m  %s\n' "$*"; }
fail() { printf '   \033[31mFAIL\033[0m %s\n' "$*"; exit 1; }
# wait_for <seconds> <command...>: retry until the command succeeds
wait_for() { local t=$1; shift; for _ in $(seq "$t"); do "$@" >/dev/null 2>&1 && return 0; sleep 1; done; return 1; }
started() { docker inspect -f '{{.State.StartedAt}}' "$1"; }
cid()     { docker inspect -f '{{.Id}}' "$1" | cut -c1-12; }
page_has() { curl -fsS "$BASE$1" | grep -q -- "$2"; }
status_is() { [ "$(curl -s -o /dev/null -w '%{http_code}' "$BASE$1")" = "$2" ]; }

cleanup() {
  set +e
  bold "Cleanup: stop watcher, restore files, recreate containers from the committed sources"
  [ -n "$WATCH_PID" ] && kill "$WATCH_PID" 2>/dev/null && wait "$WATCH_PID" 2>/dev/null
  for f in "${EDITED[@]}"; do cp -f "$WORK/$f" "$f"; done
  rm -f "${CREATED[@]}"
  docker compose up -d --build --force-recreate --wait --quiet-pull >/dev/null 2>&1 \
    && ok "stack back to its original state" || echo "   run 'make start' to recover"
  echo "   watch log kept at $WATCH_LOG"
}

if pgrep -f '^docker compose .*watch' >/dev/null; then
  echo "Another 'docker compose watch' / 'up --watch' is running. Stop it first (two watchers would both react)." >&2
  exit 1
fi

for f in "${EDITED[@]}"; do mkdir -p "$WORK/$(dirname "$f")"; cp "$f" "$WORK/$f"; done
trap cleanup EXIT

bold "Start the stack detached (seed -> site/api -> healthy -> gateway)"
# --force-recreate: synced files live in the container layer, so start from clean containers
docker compose up -d --build --force-recreate --wait
ok "$(docker inspect -f '{{.State.Status}} (exit {{.State.ExitCode}})' watch-seed): seed job"
curl -fsS "$BASE/meta/stack-info.json"; echo

# ---------------------------------------------------------------------------
bold "1. initial_sync: edit site/html/index.html while NOTHING is watching"
sed -i 's/Hello from the site service (action: sync)/Edited while watch was off (initial_sync)/' site/html/index.html
page_has / "initial_sync" && fail "change visible before watch started?" || ok "not visible yet (no watcher)"

docker compose watch --no-up >"$WATCH_LOG" 2>&1 &
WATCH_PID=$!
wait_for 30 grep -q "Watch enabled" "$WATCH_LOG" || fail "watch did not start (see $WATCH_LOG)"
ok "watch started (pid $WATCH_PID)"
wait_for 15 page_has / "initial_sync" && ok "initial_sync pushed the offline edit on watch start" || fail "initial_sync"

# ---------------------------------------------------------------------------
bold "2. action: sync (site): edit index.html, no restart"
before=$(started watch-site)
sed -i 's/Edited while watch was off (initial_sync)/Live edit via sync, no restart/' site/html/index.html
echo '<p>brand new page</p>' > site/html/new.html
wait_for 15 page_has / "Live edit via sync" && ok "GET / shows the new text" || fail "sync"
wait_for 15 page_has /new.html "brand new page" && ok "new file /new.html served" || fail "sync new file"
[ "$(started watch-site)" = "$before" ] && ok "watch-site was NOT restarted (StartedAt $before)" || fail "site restarted"

# ---------------------------------------------------------------------------
bold "3. ignore (site): drafts/ and *.tmp never reach the container"
echo '<p>wip</p>' > site/html/drafts/wip.html
echo 'scratch' > site/html/notes.tmp
sleep 4
status_is /drafts/wip.html 404 && ok "/drafts/wip.html -> 404 (ignored: drafts/)" || fail "drafts synced"
status_is /notes.tmp 404       && ok "/notes.tmp -> 404 (ignored: *.tmp)"         || fail "tmp synced"

# ---------------------------------------------------------------------------
bold "4. action: sync+exec + include (notes): sync *.txt, then run build-notes"
build() { curl -fsS "$BASE/notes/" | grep -o 'build #[0-9]*'; }
b0=$(build)
echo 'scratch' > notes/content/scratch.md
sleep 4
[ "$(build)" = "$b0" ] && ok "scratch.md ignored by include [*.txt]: still $b0" || fail "include"
printf 'Added by scripts/demo.sh at %s\n' "$(date +%T)" > notes/content/03-demo.txt
wait_for 15 page_has /notes/ "03-demo" && ok "page regenerated in place: $b0 -> $(build), new note listed" || fail "sync+exec"

# ---------------------------------------------------------------------------
bold "5. action: sync+restart (gateway): change nginx.conf"
before=$(started watch-gateway)
sed -i 's/X-Demo-Banner "v1"/X-Demo-Banner "v2"/' gateway/nginx.conf
banner() { curl -fsSI "$BASE/" | tr -d '\r' | grep -qi '^X-Demo-Banner: v2'; }
gw_restarted() { [ "$(started watch-gateway)" != "$before" ]; }
wait_for 30 gw_restarted && ok "watch-gateway restarted: $before -> $(started watch-gateway)" || fail "gateway not restarted"
wait_for 30 banner && ok "response header X-Demo-Banner: v2" || fail "sync+restart gateway"

# ---------------------------------------------------------------------------
bold "6. action: sync+restart (api): change app.py (no image build)"
id0=$(cid watch-api)
sed -i 's/hello from api v1/hello from api v2/' api/app.py
wait_for 30 page_has /api/ "hello from api v2" && ok "greeting is now v2" || fail "sync+restart api"
[ "$(cid watch-api)" = "$id0" ] && ok "same container ($id0), just restarted" || fail "api was recreated"

# ---------------------------------------------------------------------------
bold "7. action: rebuild (api): add a dependency to pyproject.toml"
sed -i 's/    "cowsay==6.1",/    "cowsay==6.1",\n    "pyfiglet==1.0.2",/' api/pyproject.toml
echo "   building image with uv (watch log shows the build)..."
wait_for 180 page_has /api/ '"pyfiglet"' && ok "pyfiglet installed; image rebuilt, container recreated: $id0 -> $(cid watch-api)" || fail "rebuild"
curl -fsS "$BASE/api/" | python3 -c 'import json,sys; print(json.load(sys.stdin)["figlet"])' 2>/dev/null || true

# ---------------------------------------------------------------------------
bold "What watch logged"
grep -E 'Syncing|restarted|Rebuilding|built|build-notes' "$WATCH_LOG" | sed 's/^/   /'
bold "All watch actions verified"
