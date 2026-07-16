# Welcome to ClaudeView

The viewer is live — if you can read this, the server is up and watching the
directory named in the header above. This is the **seed tab**: it appears only
while the watched directory is otherwise empty, so treat it as a *setup
checklist*. Work through it, then let Claude fill this screen instead.

ClaudeView mirrors Claude Code's **long-format output** — plans, research,
reviews, backlogs — onto a dedicated surface (ideally a portrait second monitor),
updating on its own. Each `.md` file in the watched directory becomes a tab; the
newest is shown automatically. Two things feed it, and both need a one-time wire-up.

## Finish the setup

- [ ] **Wire the hooks** — merge `hooks/settings.snippet.json` from your checkout
      into `~/.claude/settings.json`, editing the two absolute paths to point at it.
      Mirrors every **plan** (before you approve) and each turn's **last message**.
- [ ] **Pre-approve the writes** — add `"Edit(~/.claudeview/**)"` to
      `permissions.allow` in `~/.claude/settings.json`, so Claude never asks before
      writing a tab.
- [ ] **Expose `claudeview-session`** — `ln -s "$PWD/bin/claudeview-session"
      ~/.local/bin/`, so a manual `Write` groups with the hook's tabs under one
      `repo@branch`.
- [ ] **Teach Claude the convention** — add the tab-writing line (below) to your
      project or global `CLAUDE.md`.
- [ ] **Restart Claude Code** — hooks are read at session start.

Add this line to `CLAUDE.md` so Claude can open a tab on purpose:

> To display something on the ClaudeView viewer, write it to
> `~/.claudeview/$(claudeview-session)~<doc>.md`, where `<doc>` names the kind of
> document (`review`, `research`, `notes`). Reuse a stable `<doc>` so an update
> replaces that tab.

Then delete this file (`rm ~/.claudeview/welcome.md`); it only reappears if the
directory is emptied again.

## Where tabs come from

| Source | Tab |
|--------|-----|
| `PreToolUse` / `ExitPlanMode` hook | `plan` (appears *before* you approve) |
| `Stop` hook | the turn's last message |
| Your `Write` to `<name>.md` | `<name>` |
| `POST /push?tab=<name>` | `<name>` (remote / home-lab) |

## Prove it without Claude

```bash
echo "# Hi" > ~/.claudeview/scratch.md                     # a 'scratch' tab
curl -X POST 'http://localhost:4790/push?tab=note' \
     --data-binary '# Pushed over HTTP'                     # a 'note' tab
```

## Reading, hands-free

- **Pin** (📌, top-left of the body) holds the current document so another
  session's output can't swap it out mid-read. Scrolling off the top pins
  automatically; scrolling back releases.
- While pinned, a group that gains a new document shows a small **red dot** — click
  the group to jump to it.

> Blockquotes, tables, task lists, highlighted code and diagrams are all themed
> for a portrait monitor. See the project README for the full tour.
