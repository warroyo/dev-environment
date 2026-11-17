---
name: github-repo
description: Only for repos owned by the warroyo GitHub account (git remote github.com/warroyo/...), never shared orgs such as modern-apps-5. How Will's personal GitHub repos are laid out and documented - README structure (overview, how it works, quick start, repo structure), status and release badges, and the docs/ folder organized by Diataxis type (tutorials, how-to, reference, explanation). Use when creating a repo, writing or reorganizing a README, adding docs, deciding where a doc page goes or what doc type it is, adding GitHub Actions workflows or releases, or when asked to "clean up the docs", "fix the README", "add badges", "apply diataxis", or "docify" a repo. Not for blog posts (will-prose) or vault notes (second-brain).
---

# GitHub repo conventions

**Scope: only repos whose GitHub owner is `warroyo`.** Check first with
`git remote get-url origin` (or `gh repo view --json owner -q .owner.login`).
If the owner is anything else, a shared or team org such as `modern-apps-5`,
do not apply this skill: follow that repo's own conventions instead, and do
not restructure its docs or add badges unless asked.

Will's preference, stated 2026-10-23 on warroyo/platform-observability-addon:
a README is short and ordered for a newcomer. Depth lives in `docs/`.

Docs follow [Diataxis](https://diataxis.fr/) (adopted 2026-11-17): every page
is one of four types - tutorial, how-to, reference or explanation - and never
a mix.

Existing repos are not refactored in bulk. Apply this layout to a repo when
its docs are next touched, or when asked.

## README: four sections, in this order

Title, then the badges, then:

1. **Overview** (explanation) - what it is and what it automates for the
   user, in a few sentences. Describe the outcome, not the manual process it
   replaces: no walkthrough of a vendor UI, dialog or the steps people used
   to copy by hand.
2. **How it works** (explanation) - the moving parts and the flow between
   them, in a short list or a small mermaid diagram. Enough to build a mental
   model, no more. End with a link to `docs/explanation/architecture.md` when
   it exists.
3. **Quick start** (how-to) - the shortest path to a working result:
   prerequisites (versions), then numbered steps with copy-paste commands. No
   theory and no options inline: link to `docs/how-to/` for other tasks and
   to `docs/tutorials/` when the repo has one.
4. **Repo structure** (reference) - a short tree or list of the top-level
   directories and key files, one line each, ending with one link to
   `docs/README.md` rather than a list of every docs page.

Nothing else in the README. If a section is growing past a screen, move the
detail into `docs/` and leave one line with a link.

## docs/

Move anything beyond those four sections here, into one folder per Diataxis
type. Create a folder only when it gets its first page; a repo with a single
docs page may keep it at the `docs/` root.

```
docs/
  README.md        index: one line per page, grouped by type
  tutorials/       only when the repo teaches something
  how-to/
  reference/
  explanation/
```

Use these names, and only the ones the repo needs:

| File | Holds |
|---|---|
| `docs/README.md` | the index: each page, one line, under a heading per type |
| `docs/tutorials/<lesson>.md` | a guided lesson for a newcomer, end to end |
| `docs/how-to/upgrade.md` | version-to-version upgrade steps |
| `docs/how-to/develop.md` | building, testing, releasing, pre-release gates |
| `docs/how-to/<task>.md` | one operational task, titled by its goal |
| `docs/reference/configuration.md` | full values/flags/environment tables |
| `docs/reference/rbac.md` | permissions, RBAC and object-ownership tables |
| `docs/reference/<topic>.md` | how an API, CRD or vendor quirk behaves, described not explained |
| `docs/explanation/architecture.md` | components, data flow, failure modes, scale: why it is shaped this way |
| `docs/explanation/decisions.md` | one entry per decision: date, context, decision, alternatives rejected and why |
| `docs/explanation/<topic>.md` | background, gotchas and tradeoffs for one component |

### Writing each type

- **Tutorial** - a lesson with a guaranteed result. The reader learns by
  doing: no choices, no options, explanation only as links.
- **How-to** - titled by the goal ("Upgrade from 1.x", "Rotate the token").
  Assumes the reader knows the basics. Numbered steps only, no background.
- **Reference** - describes, never instructs. Tables and lists whose
  structure mirrors the code (flags, values, CRD fields). No steps, no
  opinions.
- **Explanation** - why it works this way: context, alternatives, tradeoffs,
  gotchas. No steps.

To classify a page, ask: is the reader acting or understanding, and learning
or working? Acting and learning is a tutorial; acting and working is a
how-to; understanding and working is reference; understanding and learning
is explanation. A page that answers both ways gets split.

### No FAQ

Do not write a `docs/faq.md`. Put each question where its type lives: a
gotcha into the explanation page for that component, a "how do I X" into
`docs/how-to/x.md`, a "what does flag Y do" into reference.

### Sub-projects

A sub-project in the repo (a controller, a service) gets the same treatment:
its README keeps the four sections for that component, and its depth goes
into the shared `docs/` type folders or its own `docs/` with the same layout.

### Moving text

Moving text is a move, not a rewrite: keep facts, dates and test results.
When a page mixes types, split it along the type boundary and move each part
as is. Fix links after the move, including `docs/README.md` and the README's
repo structure (`grep -rn '](.*#' --include=*.md`, and grep for the old file
name).

## Badges

Directly under the title, one line, no others:

- one status badge per GitHub Actions workflow that matters (build, test,
  release):
  `[![test](https://github.com/<owner>/<repo>/actions/workflows/<file>.yaml/badge.svg)](https://github.com/<owner>/<repo>/actions/workflows/<file>.yaml)`
- a release badge when the repo cuts GitHub releases:
  `[![release](https://img.shields.io/github/v/release/<owner>/<repo>?sort=semver)](https://github.com/<owner>/<repo>/releases)`
- several release trains distinguished by tag prefix (e.g. `onboarder-v*`):
  one badge per train with `filter`, e.g. `?filter=onboarder-v*&sort=semver`.
- a helm chart: publish it to OCI on GitHub Packages (`helm push` to
  `oci://ghcr.io/<owner>/<repo>/charts`), not a GitHub Pages index, and have
  the release workflow create a GitHub release `<chart>-<version>` per version,
  so the chart gets a release badge with `filter=<chart>-*`.

Check every badge URL resolves (`curl -sI`) before committing.

## Voice

Plain, direct technical English: short sentences, active voice, present
tense, sentence-case headings, backticked identifiers, no marketing words, no
emoji. For text that should sound like Will, use the `will-prose` skill.
