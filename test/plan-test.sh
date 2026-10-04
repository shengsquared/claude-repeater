#!/usr/bin/env bash
# Runs the "Plan" step of .github/workflows/claude.yml, verbatim, against a fake
# clock. Only the outside world is stubbed: `date` (reads the fake clock), `sleep`
# (advances it), `gh` (run history and live runs) and `npm`. What runs here is
# what ships, so the assertions are about real behaviour.
#
# Each case prints  <role>/<action> @ <Madrid time the step finished>
#   role   survivor = this run owns the relay,  exit = it stood aside
#   action ping / hop (slept HOP, hands off) / none (replan) / dry
set -uo pipefail
cd "$(dirname "$0")/.."
WF=.github/workflows/claude.yml
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# --- pull the plan step's script out of the workflow (no YAML dependency) ---
awk '
  /^        id: plan$/            { instep=1 }
  instep && /^        run: \|$/   { body=1; next }
  body {
    if ($0 !~ /^          / && $0 !~ /^[[:space:]]*$/) exit
    sub(/^          /, ""); print
  }
' "$WF" > "$TMP/plan.sh"
[ -s "$TMP/plan.sh" ] || { echo "could not extract the plan step"; exit 1; }
TARGETS=$(awk -F'"' '/^      TARGETS:/ {print $2}' "$WF")

# --- stubs ---
export CLOCK="$TMP/clock" GITHUB_OUTPUT="$TMP/out"
mkdir -p "$TMP/bin"
cat > "$TMP/bin/date" <<'EOF'
#!/bin/bash
if [ "$#" -eq 1 ] && [ "${1:0:1}" = "+" ]; then exec /usr/bin/date -d "@$(cat "$CLOCK")" "$1"; fi
exec /usr/bin/date "$@"
EOF
cat > "$TMP/bin/sleep" <<'EOF'
#!/bin/bash
echo $(( $(cat "$CLOCK") + $1 )) > "$CLOCK"
EOF
cat > "$TMP/bin/npm" <<'EOF'
#!/bin/bash
exit 0
EOF
cat > "$TMP/bin/gh" <<'EOF'
#!/bin/bash
now=$(cat "$CLOCK")
case "$*" in
  *"--status in_progress"*)      # LIVE_IDS: "id" or "id:gone_at_epoch"
    for e in ${LIVE_IDS:-}; do
      id=${e%%:*}; until=${e#*:}; [ "$until" = "$e" ] && until=99999999999
      [ "$now" -lt "$until" ] && echo "$id"
    done; exit 0 ;;
  *"--status queued"*) exit 0 ;;
  *displayTitle*)                # the pause lookup: newest PAUSE/RESUME run, "title|created"
    row=""
    if [ -n "${FAKE_PAUSE_AT:-}" ] && [ "$now" -ge "$FAKE_PAUSE_AT" ]; then
      row="PAUSE 24h|$(/usr/bin/date -u -d "@$FAKE_PAUSE_AT" +%Y-%m-%dT%H:%M:%SZ)"; fi
    if [ -n "${FAKE_RESUME_AT:-}" ] && [ "$now" -ge "$FAKE_RESUME_AT" ]; then
      row="RESUME|$(/usr/bin/date -u -d "@$FAKE_RESUME_AT" +%Y-%m-%dT%H:%M:%SZ)"; fi
    echo "${row:-null|null}"; exit 0 ;;
  *"run list"*) [ -n "${FAKE_LAST:-}" ] && echo 1; exit 0 ;;
  *api*)
    l="${FAKE_LAST:-}"
    if [ -n "${FAKE_LAST_LATE:-}" ] && [ "$now" -ge "${FAKE_LATE_AT:-0}" ]; then l="$FAKE_LAST_LATE"; fi
    [ -n "$l" ] && /usr/bin/date -u -d "@$l" +%Y-%m-%dT%H:%M:%SZ
    exit 0 ;;
esac
EOF
chmod +x "$TMP/bin"/*

mad() { TZ=Europe/Madrid /usr/bin/date -d "$1" +%s; }
pass=0; fail=0

# decide <now> <last-ping or ""> : run the step, print the outcome
decide() {
  mad "$1" > "$CLOCK"
  if [ -n "$2" ]; then export FAKE_LAST; FAKE_LAST=$(mad "$2"); else unset FAKE_LAST; fi
  export TARGETS GITHUB_REPOSITORY=o/r GITHUB_RUN_ID=1000
  export GITHUB_EVENT_NAME="${EV:-workflow_dispatch}" CHAIN="${CHAIN:-true}"
  : > "$GITHUB_OUTPUT"
  if ! PATH="$TMP/bin:$PATH" bash --noprofile --norc -eo pipefail "$TMP/plan.sh" > "$TMP/log" 2>&1; then
    echo "SCRIPT-ERROR"; sed 's/^/        | /' "$TMP/log" >&2; return
  fi
  local role action
  role=$(grep -oE '^role=.*' "$GITHUB_OUTPUT" | tail -1 | cut -d= -f2)
  action=$(grep -oE '^action=.*' "$GITHUB_OUTPUT" | tail -1 | cut -d= -f2)
  printf '%s/%s @ %s' "${role:-?}" "${action:-?}" "$(TZ=Europe/Madrid /usr/bin/date -d "@$(cat "$CLOCK")" '+%b%d %H:%M:%S')"
}
t() { # desc now last expected   (env for the case is set by the caller)
  local got; got=$(decide "$2" "$3")
  if [ "$got" = "$4" ]; then pass=$((pass+1)); printf '  ok   %-52s %s\n' "$1" "$got"
  else fail=$((fail+1)); printf '  FAIL %-52s got  %s\n       %52s want %s\n' "$1" "$got" "" "$4"; fi
}
# The relay runs by default: a run started by the previous one (workflow_dispatch, chain=true).

echo "the relay in steady state: every ping lands on its anchor"
t "03:00 ping -> 08:01"          "2026-09-21 03:00:20" "2026-09-21 03:00:08" "survivor/ping @ Sep21 08:01:00"
t "08:01 ping -> 13:02"          "2026-09-21 08:01:20" "2026-09-21 08:01:08" "survivor/ping @ Sep21 13:02:00"
t "13:02 ping -> 18:03"          "2026-09-21 13:02:20" "2026-09-21 13:02:08" "survivor/ping @ Sep21 18:03:00"
t "18:03 ping -> 03:00 is 8h56m: hop 5h30m" "2026-09-21 18:03:20" "2026-09-21 18:03:08" "survivor/hop @ Sep21 23:33:20"
t "  ...and the next run finishes the leg"  "2026-09-21 23:33:30" "2026-09-21 18:03:08" "survivor/ping @ Sep22 03:00:00"

echo "the two bugs that took anchors on 18-19 Sep"
t "a late ping serves its anchor (was discarded)" "2026-09-19 16:28:00" "2026-09-19 13:07:04" "survivor/ping @ Sep19 18:07:04"
t "an evening run hops (was killed at the timeout)" "2026-09-18 21:03:00" "2026-09-18 17:25:00" "survivor/hop @ Sep19 02:33:00"

echo "delivered late: serve the anchor if it is within 90 minutes, else skip the slot"
t "08:01 missed by 60 min: catch up now"    "2026-09-28 09:00:57" "2026-09-28 03:00:08" "survivor/ping @ Sep28 09:00:57"
t "18:03 missed by 63 min: catch up now"    "2026-09-21 19:06:00" "2026-09-21 13:02:08" "survivor/ping @ Sep21 19:06:00"
t "13:02 missed by 4h32m: wait for 18:03"   "2026-09-28 17:34:30" "2026-09-28 09:00:57" "survivor/ping @ Sep28 18:03:00"
t "exactly 90:00 late: still served"        "2026-09-21 09:31:00" "2026-09-21 03:00:08" "survivor/ping @ Sep21 09:31:00"
t "90:01 late: slot skipped, wait for 13:02" "2026-09-21 09:31:01" "2026-09-21 03:00:08" "survivor/ping @ Sep21 13:02:00"
t "floor delays an anchor 42 min: still served" "2026-09-23 16:00:00" "2026-09-23 13:45:20" "survivor/ping @ Sep23 18:45:20"
t "floor pushes past 90 min: skip to 03:00" "2026-09-21 17:40:00" "2026-09-21 17:34:32" "survivor/hop @ Sep21 23:10:00"
t "no history at 16:28: wait for 18:03"     "2026-09-21 16:28:00" ""                    "survivor/ping @ Sep21 18:03:00"
t "no history at 13:40: 13:02 is 38 min late" "2026-09-21 13:40:00" ""                  "survivor/ping @ Sep21 13:40:00"

echo "a leg ends exactly at the hop limit"
t "5h30m out: sleeps straight through"      "2026-09-21 21:30:00" "2026-09-21 18:03:08" "survivor/ping @ Sep22 03:00:00"
t "5h30m + 1s out: hops"                    "2026-09-21 21:29:59" "2026-09-21 18:03:08" "survivor/hop @ Sep22 02:59:59"

echo "manual and dry runs"
EV=workflow_dispatch CHAIN=false t "manual run pings now, ignoring the floor" "2026-09-21 18:03:30" "2026-09-21 18:00:00" "survivor/ping @ Sep21 18:03:30"
DRY_RUN=true t "dry run plans but never pings"  "2026-09-21 03:00:20" "2026-09-21 03:00:08" "survivor/dry @ Sep21 08:01:00"

echo "only one run holds the relay"
EV=schedule CHAIN= LIVE_IDS="999" t "cron run stands aside for a live run"  "2026-09-21 12:00:00" "2026-09-21 08:01:08" "exit/none @ Sep21 12:00:00"
EV=schedule CHAIN= LIVE_IDS="1001" t "cron run stands aside for a newer one too" "2026-09-21 12:00:00" "2026-09-21 08:01:08" "exit/none @ Sep21 12:00:00"
EV=schedule CHAIN= t "cron run restarts a dead relay"  "2026-09-21 12:00:00" "2026-09-21 08:01:08" "survivor/ping @ Sep21 13:02:00"
LIVE_IDS="999" t "relay run stands down for an older run (after 2 min)" "2026-09-21 12:00:00" "2026-09-21 08:01:08" "exit/none @ Sep21 12:02:00"
LIVE_IDS="999:$(mad '2026-09-21 12:00:10')" t "relay run waits out the run that started it" "2026-09-21 12:00:00" "2026-09-21 08:01:08" "survivor/ping @ Sep21 13:02:00"
LIVE_IDS="1001" t "relay run ignores a newer run"    "2026-09-21 12:00:00" "2026-09-21 08:01:08" "survivor/ping @ Sep21 13:02:00"

echo "a ping lands while the run sleeps"
FAKE_LAST_LATE=$(mad '2026-09-21 05:00:00') FAKE_LATE_AT=$(mad '2026-09-21 05:00:01') \
  t "it would open nothing: replan, do not ping" "2026-09-21 03:05:00" "2026-09-21 03:00:08" "survivor/none @ Sep21 08:00:30"

echo "emergency pause (a PAUSE run in the history holds every ping for 24 hours)"
FAKE_PAUSE_AT=$(mad '2026-10-04 23:00:00') \
  t "paused at start: idles, hands off at the run budget"  "2026-10-04 23:07:00" "2026-10-04 18:03:08" "survivor/none @ Oct05 04:37:00"
FAKE_PAUSE_AT=$(mad '2026-10-04 12:00:00') \
  t "the pause lifts itself 24h after it was set"          "2026-10-05 11:50:00" "2026-10-04 08:01:08" "survivor/none @ Oct05 12:00:00"
FAKE_PAUSE_AT=$(mad '2026-10-04 12:00:00') FAKE_RESUME_AT=$(mad '2026-10-04 12:30:00') \
  t "a RESUME run cancels it within 10 min"                "2026-10-04 12:20:00" "2026-10-04 08:01:08" "survivor/none @ Oct04 12:30:00"
FAKE_PAUSE_AT=$(mad '2026-10-03 12:00:00') \
  t "a pause older than 24h is ignored"                    "2026-10-04 13:00:00" "2026-10-04 08:01:08" "survivor/ping @ Oct04 13:02:00"
FAKE_PAUSE_AT=$(mad '2026-10-04 06:00:00') \
  t "set while a run sleeps: caught before it pings"       "2026-10-04 03:05:00" "2026-10-04 03:00:08" "survivor/none @ Oct04 08:00:30"
FAKE_PAUSE_AT=$(mad '2026-10-04 12:00:00') EV=workflow_dispatch CHAIN=false \
  t "a manual run is deliberate and ignores the pause"     "2026-10-04 13:00:00" "2026-10-04 08:01:08" "survivor/ping @ Oct04 13:00:00"
OVERRIDE=pause_24h t "the pause run only records itself"   "2026-10-04 13:00:00" "2026-10-04 08:01:08" "exit/none @ Oct04 13:00:00"
OVERRIDE=resume    t "the resume run only records itself"  "2026-10-04 13:00:00" "2026-10-04 08:01:08" "exit/none @ Oct04 13:00:00"

echo "the pause lookup's jq filter, run for real (the gh stub above bypasses it)"
FILTER=$(grep -o "\-q '\[.*" "$WF" | head -1 | sed "s/^-q '//; s/' \\\\\$//; s/'\$//")
jqcase() { # desc json expected
  local got; got=$(jq -r "$FILTER" <<<"$2" 2>&1)
  if [ "$got" = "$3" ]; then pass=$((pass+1)); printf '  ok   %-52s %s\n' "$1" "$got"
  else fail=$((fail+1)); printf '  FAIL %-52s got  %s\n       %52s want %s\n' "$1" "$got" "" "$3"; fi
}
if command -v jq >/dev/null; then
  N='{"displayTitle":"Claude repeater","createdAt":"2026-10-04T12:00:00Z"}'
  P='{"displayTitle":"PAUSE 24h","createdAt":"2026-10-04T11:00:00Z"}'
  R='{"displayTitle":"RESUME","createdAt":"2026-10-04T13:00:00Z"}'
  P2='{"displayTitle":"PAUSE 24h","createdAt":"2026-10-04T14:00:00Z"}'
  jqcase "no pause or resume in the history"        "[$N]"          "null|null"
  jqcase "empty history"                            "[]"            "null|null"
  jqcase "a pause among normal runs"                "[$N,$P,$N]"    "PAUSE 24h|2026-10-04T11:00:00Z"
  jqcase "a resume newer than the pause wins"       "[$R,$N,$P]"    "RESUME|2026-10-04T13:00:00Z"
  jqcase "a second pause newer than the resume wins" "[$P2,$R,$P]"  "PAUSE 24h|2026-10-04T14:00:00Z"
else
  echo "  (jq not installed: skipping the filter checks)"
fi

echo "midnight and DST"
t "second before midnight"                  "2026-09-21 23:59:59" "2026-09-21 18:03:05" "survivor/ping @ Sep22 03:00:00"
t "second after midnight"                   "2026-09-22 00:00:01" "2026-09-21 18:03:05" "survivor/ping @ Sep22 03:00:00"
t "spring-forward night (3h to 03:00 CEST)" "2027-03-27 23:00:00" "2027-03-27 18:03:05" "survivor/ping @ Mar28 03:00:00"
t "spring-forward day"                      "2027-03-28 03:00:20" "2027-03-28 03:00:08" "survivor/ping @ Mar28 08:01:00"
t "fall-back night (4h30m to 03:00)"        "2026-10-24 23:30:00" "2026-10-24 18:03:05" "survivor/ping @ Oct25 03:00:00"
t "fall-back day"                           "2026-10-25 03:00:20" "2026-10-25 03:00:08" "survivor/ping @ Oct25 08:01:00"

echo; echo "passed=$pass failed=$fail"; [ "$fail" -eq 0 ]
