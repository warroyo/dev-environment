---
description: Turn a dev-log idea into an approved, public-safe blog post brief
argument-hint: <slug> [angle or notes]
---

Build the brief for one post and walk its redaction list with the user.

**This command is the boundary.** `~/dev-log` is private and deliberately
unfiltered — internal command output, vendor detail, half-formed notes. The blog
is public. The brief written here is the *only* thing allowed to cross, and it
does not cross until the user has approved every redaction. Nothing downstream
re-checks what you let through, so do not treat this as a formality.

Slug comes from `$ARGUMENTS` (first word); anything after it is the user's own
steer on angle, and should be honoured.

1. Identify the source entries in `~/dev-log/entries/`.

   The post does **not** have to have come from a `/post-ideas` survey — the user
   may simply describe what they want to write, and the words after the slug are
   that description. Search on substance rather than keywords, pull in partial
   matches from entries that are mostly about something else, and say which
   entries you matched and why before going further.

   If the description is not covered by the log, say so before drafting anything
   rather than assembling a thin brief around it. If you genuinely cannot tell
   which entries are meant, ask rather than guess.
2. Draft the brief at `$DEV_LOG_PITCHES/<slug>.md`:

   ```yaml
   ---
   slug: <slug>
   status: draft
   sources: [entries/....md, entries/....md]
   ---
   ```

   Then the body:
   - **Title**, **summary** (one sentence — it becomes the Hugo `summary`), and
     **tags**. Reuse the site's existing tag vocabulary rather than inventing
     new ones; read a few `content/posts/*/index.md` front matters in
     `~/workspace/warroyo-blog` to see what's in use.
   - **Outline** — headings only, in order. No prose. The user writes the prose
     later by dictating it; anything you write here is something they have to
     delete.
   - **Code and commands** — lifted **verbatim** from the entries. These are the
     reusable part and the reason the log exists. Copy exactly; do not tidy,
     re-indent, or "improve" them. Note which are pre-redaction (see below).
   - **Figures** — the screenshots, diagrams, and terminal captures the post
     needs, and which of them do not exist yet.
   - **Redactions** — see below.
3. Build the **Redactions** section. Go through the source entries *and* the
   code blocks line by line and flag every one of:
   - internal or lab hostnames, IPs, subnets, DNS names
   - cluster, namespace, and VM names (`authtest`, `dev-1-y8qw4`, and the like)
   - credentials, tokens, client secrets, kubeconfig contents, certificates —
     including ones that look like examples
   - customer, employer-internal, or coworker names
   - internal-only URLs: dashboards, ticket systems, wikis, private repos
   - unreleased, embargoed, or NDA-covered product behaviour
   - internal reasoning about a vendor that shouldn't be published as-is

   Each flag gets: what it is, where it appears, why it's flagged, and a
   **proposed replacement** (`authtest` → `demo-cluster`, a real IP → an
   RFC 5737 documentation address, a secret → an obvious placeholder). Never
   leave a real secret in place with a note to fix it later.

   Judge the *content*, not the pattern. A public product version number is
   fine; a hostname that happens to look generic may still be real. When you
   are unsure, flag it and let the user decide — a false positive costs them one
   word, a false negative is published.
4. **Walk the list with the user, item by item.** Do not batch it into a wall
   they'll skim. For each: state the flag and the proposal, take keep / change /
   drop-the-section. This step is meant to be done out loud, so keep each one
   short enough to hear.
5. Apply every decision to the brief, then set `status: pitched`. **Do not set
   `pitched` until every item has been answered.** If the user stops partway,
   leave `status: draft` and say which items are still open — a half-approved
   brief must not look ready to scaffold.
6. Commit the pitch to `~/dev-log` **and push it**, matching what
   `dev-log-entry` does for entries — best-effort, so a failed push (offline,
   no credentials) does not fail the brief:

   ```sh
   git -C ~/dev-log add pitches/ && git -C ~/dev-log commit -q -m "<message>"
   git -C ~/dev-log push -q >/dev/null 2>&1 || true
   ```

   A pitch that only exists on one machine defeats the point — the whole flow is
   meant to be resumable from the phone. Say whether the push landed; if it did
   not, say so plainly rather than implying it synced.
7. Tell the user the path, the redaction count, and that
   `/post-scaffold <slug>` is next (run from `~/workspace/warroyo-blog`).

If a finding cannot be published at all — an unreleased feature is the whole
point of the post — say so and stop. A post that has to be gutted to be safe is
better parked than published hollow.
