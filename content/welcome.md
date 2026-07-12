# ClaudeView

If you can read this, the viewer is live.

This surface mirrors Claude Code's **long-format output** — plans, research,
reviews, backlogs — and updates on its own. Each `.md` file in the watched
directory becomes a tab; the newest one is shown automatically.

## Try it

- Drop a file: `echo "# Hi" > content/scratch.md`
- Push over HTTP: `curl -X POST 'http://localhost:4000/push?tab=note' --data-binary '# Pushed'`

## Rendering check

Inline `code`, a fenced block:

```elixir
defp broadcast(subs), do: Enum.each(subs, &send(&1, :changed))
```

> Blockquotes, tables and links all themed for a portrait monitor.

| Source | Tab |
|--------|-----|
| ExitPlanMode hook | `plan` |
| Stop hook | `last-message` |
| Your `Write` | `<filename>` |
