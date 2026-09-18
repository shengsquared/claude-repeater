# claude-repeater

Opens Claude usage windows at chosen times of day instead of whenever you happen
to send your first message.

A window isn't on a fixed clock. It starts the moment you send a message and
runs five hours from that timestamp. So "triggering a window at 08:05" just
means guaranteeing a message goes out at 08:05. This repo sends that message: a
one-word `claude -p "hi"` on Haiku, authenticated with a subscription OAuth
token.

## Anchors

Madrid local time: **03:00, 08:05, 13:10, 18:15**.

The five-minute stagger is deliberate. Windows are five hours long, so a new one
can only open five hours after the last message. Anchors spaced exactly five
hours apart therefore cannot hold: every ping lands a second or two late, which
pushes the next window start just past the next anchor, and the whole schedule
walks forward — half an hour per cycle in the version this replaced, so the
18:00 anchor was firing at 19:30. Five hours and five minutes absorbs the
jitter. Coverage runs 03:00 to 23:15 with four five-minute seams.

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

The last ping's timestamp lives in the Actions cache, keyed `ping-state-*`.

It used to live in an Actions Variable, which needed a fine-grained PAT, because
the built-in `GITHUB_TOKEN` structurally cannot write Variables. That PAT
expired and returned `401 Bad credentials`, which failed every run red — and
worse, silently disabled all scheduling, because the unreadable variable made
the job think its state was corrupt and ping on every single poll. The cache
needs no credential beyond the built-in token, so that failure mode is gone.

**No PAT is required any more.** `VARS_PAT` can be deleted.

A missing cache entry degrades safely: the job pings at the next anchor and
starts recording again.

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
