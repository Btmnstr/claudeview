---
name: claudeview
description: Author content for the ClaudeView second-screen viewer — name a tab so it groups under the right repo@branch session, and embed rendered diagrams and images. Use when writing a plan, review, research note or summary to ~/.claudeview, or when a tab lands in the wrong group.
---

# Putting content on ClaudeView

ClaudeView shows Markdown files from `~/.claudeview/` as tabs on a second screen.
Write the file yourself with the `Write` tool — this is the reliable path (no MCP,
no hook timing). Skip it for short or conversational replies; the surface is for
output that rewards a full screen.

## Name the tab so it groups by session

A tab name is `<session>~<doc>`. The viewer groups on the **session** (everything
before the last `~`) and shows it as `repo@branch`, so a session's documents sit
together under one tab.

Build the session part with the helper, which prints this repo's `<repo>~<branch>`
key — the same key the hook uses, so your document joins the session's `plan` and
`summary` instead of forming a stray group:

```sh
claudeview-session          # -> zombiesnack~main
```

Then write `~/.claudeview/<session>~<doc>.md`, where `<doc>` names the kind of
document — `review`, `research`, `notes`, `analysis`:

```
~/.claudeview/$(claudeview-session)~review.md      # zombiesnack~main~review.md
```

Rules of the grammar:

- **`~` is the only structural delimiter.** Don't put `~` inside a component; do
  use `-`/`_` freely (`repo~main~research-tabs` groups under `repo@main`, doc
  `research-tabs`).
- **Reuse a stable `<doc>`** so an update *replaces* that tab instead of spawning
  a new one. (`~summary` is the one exception — it appends within a short window.)
- **Case folds:** `Repo~main~x` and `repo~main~x` group together.
- **Outside a git repo** the helper prints just the directory name; supply your own
  `<intention>~<doc>` (e.g. `refactor-auth~notes`) so the work still groups.

If `claudeview-session` isn't on `PATH`, it lives in the ClaudeView repo's `bin/`;
symlink it once with `ln -s "<repo>/bin/claudeview-session" ~/.local/bin/`.

## Plan mode

In plan mode the harness lets you write only the designated plan file
(`~/.claude/plans/<slug>.md`) — a write to `~/.claudeview/` is denied. The viewer
watches the plans directory as a `plan (live)` tab, so treat the plan file as the
live document: write findings into it immediately, then overwrite with the final
plan. On ExitPlanMode the hook files an attributed `repo~branch~plan` into the
session's group.

## Diagrams and images

A tab is Markdown, so it can carry diagrams and images, all rendered server-side
to self-contained output (no browser JS). A block that fails to render is left as
its verbatim source, never a broken image — safe to lean on.

- ` ```mermaid ` — Mermaid, rendered to inline SVG.
- ` ```dot ` / ` ```graphviz ` — Graphviz `dot`, to inline SVG.
- ` ```svg ` — SVG you authored, passed through.
- `![alt](name.png)` — a relative image is served from the watched directory via
  `/media`; drop the file beside the `.md`.
