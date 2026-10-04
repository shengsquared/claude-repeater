# claude-repeater

Opens Claude usage windows at chosen times of day instead of whenever you happen
to send your first message.

A window is not on a fixed clock. It starts when you send a message and lasts
five hours. So opening one at 08:01 means making sure a message goes out at
08:01. This repo sends it: a one-word `claude -p "hi"` on Haiku, authenticated
with a subscription OAuth token (`claude setup-token`).

## Anchors

Madrid local time: **03:00, 08:01, 13:02, 18:03**, 5h01m apart, then 8h57m
overnight.

Exactly five hours apart cannot work. Every ping lands a second or two after its
anchor, so the next window can only open a second or two after the next anchor,
and the schedule walks forward. The extra minute is the margin. It is not
smaller on purpose: a ping inside a window that is still open opens nothing, but
`claude -p` still succeeds and the run still goes green, so the miss leaves no
trace. Ten seconds of margin only survives if a window is exactly five hours
from the message; a minute also survives the end rounding up.

## How it fires: a relay

GitHub's scheduler is not a clock. Measured on this repo over 21-28 Sep it
delivered 4 to 7 of the 24 hourly runs it was asked for, often hours late, and
the `timezone:` field is ignored. A run can only sleep to an anchor if one was
delivered beforehand, and 7 of 32 anchors in that stretch had no run alive when
they came, so they fired 2 minutes to 4h32m late.

So the workflow does not depend on the cron. Each run:

1. works out the next anchor, in `TZ=Europe/Madrid`, which reads system tzdata
   and handles DST;
2. sleeps to it, and sends the message on the second;
3. **starts the next run itself** with `workflow_dispatch`, which is not subject
   to the scheduler (events from the built-in token do not start new runs, except
   this one).

There is always a run alive, so delivery no longer matters. The hourly cron stays
only as a restart if the relay breaks; its delivery time is irrelevant.

A job may live six hours and the overnight gap is 8h57m, so one run cannot sleep
through it. Runs sleep at most 5h30m, then hand off, and the next run sleeps the
rest. Each leg ends on an absolute target, so hand-off delay never accumulates.
The 18:03 run hands off at 23:33 and the next one wakes for 03:00.

Cancelling the live run breaks the chain, but it is not an off switch: the next cron delivery starts the relay again, which can be minutes or hours later. To stop it for a day, use the emergency pause below.

## Which anchor a run serves

A run serves the earliest anchor it can still serve within 90 minutes of its
time, and pings at the latest of: the anchor, five hours after the last ping, and
now.

- On time: a run that starts just after a ping sleeps to the next anchor.
- A few minutes late: a ping five minutes past its anchor puts the five-hour
  floor three minutes past the next one. That anchor is served at the floor, not
  thrown away over three minutes.
- Missed by up to 90 minutes: served now.
- Missed by more: the slot is skipped and the run waits for the next anchor. A
  ping at a useless hour would open a window nobody needs and push every later
  anchor with it. On 28 Sep, catching up 13:02 at 17:34 cost the 18:03 anchor and
  would have moved 03:00 to 03:34.

Lateness therefore never cascades for more than a couple of anchors, and the
overnight gap resets it.

## State

There is no state store. "When did we last ping?" is the newest run of this
workflow whose `Ping Claude` step succeeded, read from the run history. Nothing
is written, so nothing goes stale, and no credential beyond the built-in token is
needed. It used to be an Actions Variable, which needs a personal access token;
that expired, returned `401`, and silently disabled all scheduling. `VARS_PAT`
can be deleted.

No third-party actions are used, so any restriction on which actions may run is
irrelevant. (`actions/cache` was rejected at startup on this repo.)

## One run holds the relay

A scheduled run stands aside if any run is alive. A relay run waits up to two
minutes for the run that started it to finish, and stands aside only for an
older run that is still going. Two runs that start together resolve to the older.
If two ever do sleep to the same anchor, the second ping lands inside the first
window and does nothing, and the extra run stands down at the next hand-off.

A run also re-checks the history 30 seconds before its target. If a ping landed
while it slept (a manual run, say), pinging would open nothing, so it replans.

## Emergency pause

To stop every ping for a day: **Actions, *Claude repeater*, Run workflow, set
`override` to `pause_24h`.** The run that results is named `PAUSE 24h`, and for the
next 24 hours from the moment you started it nothing is sent. Then it resumes by
itself on the next anchor; nothing to remember, nothing to undo.

- **Cancel it early:** run the workflow again with `override` set to `resume`.
  Takes effect within ten minutes.
- **Extend it:** run `pause_24h` again; the 24 hours restart from then.
- The relay stays alive while paused. Runs keep handing on, idling, and send
  nothing. That is why it resumes exactly on the next anchor with no restart.
- A run about to ping looks again 30 seconds before its target, so a pause set
  while a run sleeps is caught before the ping goes out.
- A **manual** run (`chain` off) is a deliberate ping and ignores the pause.
- The pause is recorded in the run history (the run's name and start time), so it
  needs no token and writes nothing to the repo.

To stop the workflow completely rather than pause it: cancel the run in progress and
use *Disable workflow* in the Actions tab, which also stops the cron. Cancelling
alone is not enough, because the hourly cron restarts the relay.

## Operating it

- **Start or restart the relay:** Actions, *Claude repeater*, Run workflow, with
  `chain` ticked. It waits for the next anchor. Leave `chain` off to ping
  immediately instead.
- **Stop it for good:** cancel the run in progress *and* disable the workflow (see above).
- **Pause it for a day:** see Emergency pause.
- **Test it without spending anything:** run with `dry_run` ticked and
  `hop_seconds` set to `90`. It plans, sleeps, and hands off every minute and a
  half, and never calls Claude. Cancel it when done.
- **Read a run:** the list shows when GitHub started the run, not when it pinged.
  A run that starts at 13:36 and lasts 4h26m pinged at 18:03. Open the run and read
  the `Ping Claude` step.

## Tests

`test/plan-test.sh` runs the Plan step of the workflow, verbatim, against a fake
clock that advances when the script sleeps. Only `date`, `sleep`, `gh` and `npm`
are stubbed. It covers steady state, both failures of 18-19 Sep, late delivery
and its 90-minute boundary, the hop limit, manual and dry runs, the single-holder
rules, a stray ping, midnight and both DST transitions. Deliberately breaking the
workflow (dropping the floor, the hop limit, the wait for the parent) fails it.

It cannot test that one run can start the next; that only exists on a real runner.
Use the dry run above.

## The caveat no code can catch

All of this depends on headless `claude -p` usage drawing from the same session
pool as interactive use. That is true today. Anthropic announced a change moving
non-interactive usage to a separate credit pool and then paused it with no new
date. If it resumes, every ping here keeps succeeding in the logs while doing
nothing for your interactive windows. Nothing in this workflow can detect that.
Checking `/usage` after a scheduled ping is the only way to know.
