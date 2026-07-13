# ClaudeView

If you can read this, the viewer is live.

This surface mirrors Claude Code's **long-format output** — plans, research,
reviews, backlogs — and updates on its own. Each `.md` file in the watched
directory (shown in the header above) becomes a tab; the newest one is shown
automatically.

## Try it

- Drop a file: `echo "# Hi" > ~/.claudeview/scratch.md`
- Push over HTTP: `curl -X POST 'http://localhost:4790/push?tab=note' --data-binary '# Pushed'`

## Where tabs come from

| Source | Tab |
|--------|-----|
| `PreToolUse` / `ExitPlanMode` hook | `plan` (appears *before* you approve) |
| `Stop` hook | `last-message` |
| Your `Write` to `<name>.md` | `<name>` |

> Blockquotes, tables and code are all themed for a portrait monitor.
