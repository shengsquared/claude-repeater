#!/usr/bin/env bash
# Exercises the real decision logic from .github/workflows/claude.yml against a
# fixed clock. The step is extracted verbatim; only "what time is it now", the
# GitHub API lookups and sleep are stubbed, so what runs here is what ships.
set -uo pipefail
cd "$(dirname "$0")/.."
WF=.github/workflows/claude.yml
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# --- extract the plan step's script (indentation-based; no YAML dependency) ---
awk '
  /^        id: plan$/            { instep=1 }
  instep && /^        run: \|$/   { body=1; next }
  body {
    if ($0 !~ /^          / && $0 !~ /^[[:space:]]*$/) exit
    sub(/^          /, ""); print
  }
' "$WF" > "$TMP/plan.sh"
[ -s "$TMP/plan.sh" ] || { echo "extraction failed"; exit 1; }
TARGETS=$(awk -F'"' '/^      TARGETS:/ {print $2}' "$WF")

# --- stubs ---
mkdir -p "$TMP/bin"
cat > "$TMP/bin/date" <<'EOF'
#!/bin/bash
if [ "$#" -eq 1 ] && [ "${1:0:1}" = "+" ]; then exec /usr/bin/date -d "@$FAKE_NOW" "$1"; fi
exec /usr/bin/date "$@"
EOF
cat > "$TMP/bin/gh" <<'EOF'
#!/bin/bash
case "$*" in
  *"--status in_progress"*) exit 0 ;;                                   # nothing else in flight
  *"run list"*) [ -n "${FAKE_LAST:-}" ] && echo 1; exit 0 ;;
  *api*)        [ -n "${FAKE_LAST:-}" ] && /usr/bin/date -u -d "@$FAKE_LAST" +%Y-%m-%dT%H:%M:%SZ; exit 0 ;;
esac
EOF
printf '#!/bin/bash\necho "SLEPT=$1"\n' > "$TMP/bin/sleep"
chmod +x "$TMP/bin"/*

pass=0; fail=0
# decide <now> <last|""> -> "FIRE <stamp>" | "DEFER" | "SKIP"
decide() {
  local out slept dec fire
  export TARGETS FAKE_NOW FAKE_LAST
  FAKE_NOW=$(TZ=Europe/Madrid /usr/bin/date -d "$1" +%s)
  if [ -n "$2" ]; then FAKE_LAST=$(TZ=Europe/Madrid /usr/bin/date -d "$2" +%s); else FAKE_LAST=""; fi
  export GITHUB_EVENT_NAME="${EV:-schedule}" GITHUB_REPOSITORY=o/r GITHUB_RUN_ID=9
  export GITHUB_OUTPUT="$TMP/out"; : > "$GITHUB_OUTPUT"
  out=$(PATH="$TMP/bin:$PATH" bash -e "$TMP/plan.sh" 2>&1)
  dec=$(grep -oE 'ping=(true|false)' "$GITHUB_OUTPUT" | tail -1)
  if [ "$dec" = "ping=true" ]; then
    slept=$(grep -oE 'SLEPT=[0-9]+' <<<"$out" | grep -oE '[0-9]+' || true)
    fire=$(( FAKE_NOW + ${slept:-0} ))
    TZ=Europe/Madrid /usr/bin/date -d "@$fire" '+FIRE %b%d %H:%M:%S'
  elif grep -q 'beyond the' <<<"$out"; then echo DEFER
  else echo SKIP; fi
}
t() { local got; got=$(decide "$2" "$3")
  if [ "$got" = "$4" ]; then pass=$((pass+1)); printf '  ok   %-42s %s\n' "$1" "$got"
  else fail=$((fail+1)); printf '  FAIL %-42s got=%-22s want=%s\n' "$1" "$got" "$4"; fi; }

echo "steady state - must land exactly on the anchors"
t "03:00 -> 08:01"  "2026-09-20 03:05:00" "2026-09-20 03:00:05" "FIRE Sep20 08:01:00"
t "08:01 -> 13:02"  "2026-09-20 08:10:00" "2026-09-20 08:01:05" "FIRE Sep20 13:02:00"
t "13:02 -> 18:03"  "2026-09-20 13:30:00" "2026-09-20 13:02:05" "FIRE Sep20 18:03:00"
t "18:03 -> 03:00"  "2026-09-20 22:30:00" "2026-09-20 18:03:05" "FIRE Sep21 03:00:00"

echo "regressions (both of these shipped broken on 2026-09-18)"
t "late ping must not forfeit the anchor" "2026-09-19 16:28:00" "2026-09-19 13:07:04" "FIRE Sep19 18:07:04"
t "evening must not sleep into timeout"   "2026-09-18 21:03:00" "2026-09-18 17:25:00" "FIRE Sep18 22:25:00"

echo "overnight gap (8h57m) exceeds the 6h a job may live"
t "target 8h50 out -> defer"     "2026-09-20 18:10:00" "2026-09-20 18:03:05" "DEFER"
t "maxwait + 1s   -> defer"      "2026-09-20 21:14:59" "2026-09-20 18:03:05" "DEFER"
t "maxwait exactly -> sleep"     "2026-09-20 21:15:00" "2026-09-20 18:03:05" "FIRE Sep21 03:00:00"

echo "edges"
t "cold start, no history"   "2026-09-19 16:28:00" ""                    "FIRE Sep19 16:28:00"
t "floor beats anchor"       "2026-09-20 18:03:30" "2026-09-20 17:00:00" "FIRE Sep20 22:00:00"
EV=workflow_dispatch t "manual run overrides floor" "2026-09-20 18:03:30" "2026-09-20 18:00:00" "FIRE Sep20 18:03:30"
t "second before midnight"   "2026-09-20 23:59:59" "2026-09-20 18:03:05" "FIRE Sep21 03:00:00"
t "second after midnight"    "2026-09-21 00:00:01" "2026-09-20 18:03:05" "FIRE Sep21 03:00:00"

echo "DST"
t "spring-forward night"     "2027-03-27 23:00:00" "2027-03-27 18:03:05" "FIRE Mar28 03:00:00"
t "spring-forward day"       "2027-03-28 03:05:00" "2027-03-28 03:00:05" "FIRE Mar28 08:01:00"
t "fall-back night"          "2026-10-24 23:30:00" "2026-10-24 18:03:05" "FIRE Oct25 03:00:00"
t "fall-back day"            "2026-10-25 03:10:00" "2026-10-25 03:00:05" "FIRE Oct25 08:01:00"

echo; echo "passed=$pass failed=$fail"; [ "$fail" -eq 0 ]
