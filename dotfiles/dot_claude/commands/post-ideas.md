---
description: Survey ~/dev-log for post-worthy material, or find what supports a post you already want to write
argument-hint: [description of the post you want]
---

Read the dev session log and report what is there to write about. This is
**read-only** — it writes nothing.

## Two modes

**Survey (no arguments).** You pick the candidates. Follow steps 1–6 below.

**Directed (`$ARGUMENTS` describes a post the user wants).** They pick; your job
is to find out whether the log can support it. Skip the ranking entirely and
follow *Directed mode* at the bottom instead. The description may be loose — "the
thing about tokens meaning different things", "that networking mess from a couple
weeks back" — so search on substance, not keywords, and say what you matched.

1. Read every entry in `~/dev-log/entries/*.md`. See `~/dev-log/README.md` for
   the entry format.
2. Read every pitch in `$DEV_LOG_PITCHES` (`~/dev-log/pitches/*.md`) and collect
   the entries named in their `sources:` lists. Those have already been claimed
   — exclude them, and say how many you skipped so it's clear nothing vanished
   silently.
3. Group the remaining entries into candidate posts. **One post is usually
   several entries**: the same project across several days, or one thread of a
   problem picked up and put down. Sessions are a unit of work, not a unit of
   writing, so do not assume one entry equals one post. Equally, one entry can
   hold two unrelated findings that want separate posts.
4. Judge what is actually worth publishing. Good signals: a documented claim
   turned out to be wrong and there's evidence; a diagnostic that isn't obvious
   until someone tells you (the "403 vs 401" kind); a working setup for
   something with no good public writeup; a pitfall that cost real time. Weak
   signals: routine configuration, anything already well covered elsewhere,
   a fix with no transferable lesson.
5. Rank them and print a short list. Per candidate:
   - a **working title**
   - the **angle** in one or two sentences — what the reader learns, and why
     they'd care
   - **sources** — the entry filenames feeding it
   - **evidence on hand** vs **what needs a rerun** (measurements to redo,
     screenshots to capture, a cluster to stand back up)
   - rough **size** — short / medium / long
   - anything that looks **hard to publish**: unreleased features, vendor
     internals, a customer's environment. Flag it here so it's known before
     `/post-brief` reaches it, not after.
6. Stop there and let the user pick. Do not write a pitch file — that's
   `/post-brief`.

If nothing unclaimed is worth a post yet, say so plainly and don't pad the list.

## Directed mode

The user has told you what they want to write. Do not rank, do not propose
alternatives they did not ask for, and do not talk them out of it. Report what
the log can and cannot back up:

1. **Matched material.** Which entries feed this, and the specific findings
   inside them. Quote the finding, not the filename — they want to recognise it.
   Include partial matches from entries that are mostly about something else;
   one paragraph in an unrelated session is often the best thing there is.
2. **Proven vs asserted.** Separate what was measured, run, or captured from what
   the log merely claims. The first can go in a post as-is; the second needs
   re-verification or hedging. This is the most useful thing you produce here —
   the log does not always mark the difference.
3. **Gaps.** What the described post needs that the log does not contain:
   measurements never taken, screenshots never captured, a step that worked but
   was never written down. Be specific about what would have to be re-run.
4. **Honest verdict.** One of:
   - enough here for the post as described
   - enough for a *narrower* post — say which part is actually covered
   - not enough; the material is thinner than it looks and here is what is missing
   - nothing on this at all, and it may predate the log
5. **Adjacent finding, only if there is one.** If the log shows something
   genuinely sharper sitting right next to what they asked for, mention it once,
   briefly, and leave it. Their described post still stands; you are adding an
   option, not redirecting them.

Do not inflate coverage to be encouraging. "Two entries touch this, neither
measured anything" is a more useful answer than a padded list, because the cost
of finding out at draft time is much higher.

Then stop. `/post-brief <slug> <their description>` is next, and it carries the
steer forward — a post can be briefed straight from here without ever appearing
in a survey ranking.
