# claude-repeater

Opens Claude usage windows at chosen times of day instead of whenever you happen
to send your first message.

A window isn't on a fixed clock. It starts the moment you send a message and
runs five hours from that timestamp. So "triggering a window at 08:05" just
means guaranteeing a message goes out at 08:05. This repo sends that message: a
one-word `claude -p "hi"` on Haiku, authenticated with a subscription OAuth
token.

## Anchors

European local time: **03:00, 08:01, 13:02, 18:03** — 5h01m apart.

The stagger is deliberate. Windows are five hours long, so a new one can only
open five hours after the last message. Anchors spaced exactly five hours apart
therefore cannot hold: every ping lands a second or two late, which pushes the
next window start just past the next anchor, and the whole schedule walks
forward — half an hour per cycle in the version this replaced, so the 18:00
anchor was firing at 19:30.

The extra minute is the safety margin, and it is deliberately not shorter. A
ping that lands inside a window that is still open does not start a new one, but
`claude -p` still succeeds and the run still goes green, so the miss leaves no
trace and the following target then gets computed from an anchor that never
existed. Ten seconds of margin survives only if a window is exactly five hours
from the message; a minute also survives the window end rounding up. The cost of
the larger margin is three minutes of spread across the whole day.

Coverage runs 03:00 to 23:03 with three one-minute seams. Gaps stay above five
hours across both DST transitions — spring-forward shortens the overnight gap to
7h57m, which is still ample.

## Missing an anchor vs. drifting off it

Each run aims at `max(next anchor, last ping + 5h)`, never earlier. Both halves
matter. A ping before the five hours are up lands inside the open window and
opens nothing; an anchor abandoned because it sits a couple of minutes inside
that floor costs a whole five-hour slot. Waiting the extra minutes is always the
better trade, so the job waits rather than skipping.

The cost is that a ping which lands late drags the following ones with it: the
anchors are only 5h01m apart, so any lateness beyond a minute means the floor,
not the anchor, sets the next target. That drift does not accumulate. The
overnight gap is 8h57m, far longer than the floor, so the first anchor of each
day is reached on time regardless of how ragged the previous day was — 03:00
re-acquires the phase and the rest of the day follows it.

## The overnight gap cannot be slept through

A job may live six hours at most on a hosted runner, and the gap from 18:03 to
03:00 is 8h57m. A run delivered early in that gap therefore cannot wait it out.
It exits immediately instead (`MAXWAIT`, 5h45m) and leaves 03:00 to a run
delivered later in the night.

This matters more than it sounds. A run that sleeps is holding the lock — every
other run sees it in flight and exits at once. An earlier version sized the job
timeout to the daytime anchor spacing and let evening runs sleep toward 03:00;
they were killed at the timeout having pinged nothing, and blocked every other
run for the 5h40m they spent dying.

## Why the cron expression is meaningless

Measured on this repository, GitHub's scheduler is not a clock:

- Scheduled runs arrived **one to three hours late**, in all eight samples taken
  against a four-anchor cron. Not one arrived early.
- A `0,30 * * * *` cron delivered **four runs in twelve hours** instead of
  twenty-four. High-frequency schedules get dropped; the old four-a-day cron was
  delivered reliably.
- The `timezone:` field was **ignored** and the expression executed as plain
  UTC, which is why every run looked misaligned by exactly the UTC offset.

None of that is fixable by writing a better cron expression. So the cron here is
hourly and its firing time is treated as irrelevant — it exists only to get a
runner started. Every timing decision happens inside the job, which computes the
next anchor under `TZ=Europe/Madrid` (reading system tzdata, so DST is handled)
and then **sleeps until it**. GitHub decides when the job starts; the job decides
when the ping goes out.

If a run is delivered after an anchor has already gone by unserved, it pings
immediately instead of idling until the next one.

## State

There is no state store. "When did we last ping?" is answered by reading this
workflow's own run history for the newest run whose `Ping Claude` step
succeeded. Nothing is written, so nothing can go stale, get corrupted, or
expire.

State used to live in an Actions Variable, which needed a fine-grained PAT,
because the built-in `GITHUB_TOKEN` structurally cannot write Variables. That
PAT expired and returned `401 Bad credentials`, which failed every run red —
and, worse, silently disabled all scheduling, because the unreadable variable
made the job believe its state was corrupt and ping on every single poll. The
run history needs only `actions: read` on the built-in token.

**No PAT is required any more.** `VARS_PAT` can be deleted.

The workflow also uses no third-party actions at all, which keeps it working
under any repository setting that restricts which actions may run.

## Secrets

Only one: `CLAUDE_CODE_OAUTH_TOKEN`, from `claude setup-token`.

## The caveat that no code can catch

This depends on headless `claude -p` usage drawing from the same session pool as
interactive use. That is true today. But Anthropic built, priced, and announced
a change moving non-interactive usage to a separate credit pool, emailed
eligible users, then paused it the day it was due to ship, with no new date. If
it resumes, every ping here keeps succeeding in the logs while doing nothing for
your interactive windows.

Nothing in this workflow can detect that. Checking `/usage` after a scheduled
ping is the only way to know.
