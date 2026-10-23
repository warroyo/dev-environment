---
name: github-repo
description: Only for repos owned by the warroyo GitHub account (git remote github.com/warroyo/...), never shared orgs such as modern-apps-5. How Will's personal GitHub repos are laid out and documented - README structure (overview, how it works, quick start, repo structure), status and release badges, and the docs/ folder for architecture, decisions and FAQ. Use when creating a repo, writing or reorganizing a README, adding docs, adding GitHub Actions workflows or releases, or when asked to "clean up the docs", "fix the README", "add badges", or "docify" a repo. Not for blog posts (will-prose) or vault notes (second-brain).
---

# GitHub repo conventions

**Scope: only repos whose GitHub owner is `warroyo`.** Check first with
`git remote get-url origin` (or `gh repo view --json owner -q .owner.login`).
If the owner is anything else, a shared or team org such as `modern-apps-5`,
do not apply this skill: follow that repo's own conventions instead, and do
not restructure its docs or add badges unless asked.

Will's preference, stated 2026-10-23 on warroyo/platform-observability-addon:
a README is short and ordered for a newcomer. Depth lives in `docs/`.

## README: four sections, in this order

Title, then the badges, then:

1. **Overview** - what it is and what it automates for the user, in a few
   sentences. Describe the outcome, not the manual process it replaces: no
   walkthrough of a vendor UI, dialog or the steps people used to copy by hand.
2. **How it works** - the moving parts and the flow between them, in a short
   list or a small mermaid diagram. Enough to build a mental model, no more.
3. **Quick start** - the shortest path to a working result: prerequisites
   (versions), then numbered steps with copy-paste commands. Link out for
   options and alternatives instead of covering them inline.
4. **Repo structure** - a short tree or list of the top-level directories
   and key files, one line each, ending with the `docs/` pages.

Nothing else in the README. If a section is growing past a screen, move the
detail into `docs/` and leave one line with a link.

## docs/

Move anything beyond those four sections here. Use these names, and only the
ones the repo needs:

| File | Holds |
|---|---|
| `docs/architecture.md` | components, data flow, ownership of objects, RBAC, failure modes, scale |
| `docs/decisions.md` | one entry per decision: date, context, decision, alternatives rejected and why |
| `docs/faq.md` | operational questions and gotchas, as question headings |
| `docs/configuration.md` | full values/flags/environment tables |
| `docs/upgrading.md` | version-to-version upgrade steps |
| `docs/development.md` | building, testing, releasing, pre-release gates |
| `docs/<topic>.md` | reference material that fits none of the above (an API's behaviour, a vendor quirk) |

A sub-project in the repo (a controller, a service) gets the same treatment:
its README keeps the four sections for that component, and its depth goes
into the shared `docs/` pages or its own `docs/`.

Moving text is a move, not a rewrite: keep facts, dates and test results; fix
links after the move (`grep -rn '](.*#' --include=*.md`).

## Badges

Directly under the title, one line, no others:

- one status badge per GitHub Actions workflow that matters (build, test,
  release):
  `[![test](https://github.com/<owner>/<repo>/actions/workflows/<file>.yaml/badge.svg)](https://github.com/<owner>/<repo>/actions/workflows/<file>.yaml)`
- a release badge when the repo cuts GitHub releases:
  `[![release](https://img.shields.io/github/v/release/<owner>/<repo>?sort=semver)](https://github.com/<owner>/<repo>/releases)`
- several release trains distinguished by tag prefix (e.g. `onboarder-v*`):
  one badge per train with `filter`, e.g. `?filter=onboarder-v*&sort=semver`.
- a published helm chart repo with no GitHub release: a shields `dynamic/yaml`
  badge on the chart's `index.yaml`, query `$.entries.<chart>[0].version`.

Check every badge URL resolves (`curl -sI`) before committing.

## Voice

Plain, direct technical English: short sentences, active voice, present
tense, sentence-case headings, backticked identifiers, no marketing words, no
emoji. For text that should sound like Will, use the `will-prose` skill.
