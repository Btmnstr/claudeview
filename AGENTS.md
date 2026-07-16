# AGENTS.md

Orientation for an AI assistant working in this repo. Keep it small; read the
source — it is short and heavily commented.

## What it is

ClaudeView is a browser viewer for long-form Markdown that an AI writes to a
watched directory. Each `.md` file in `WATCH_DIR` (default `~/.claudeview/`) is a
tab; the newest-modified is auto-focused. "Claude controls the viewer" is just
Claude using the `Write` tool — no plugin, no protocol.

## Architecture

One rendering pipeline, one content store. Data flows one way:

```
file write → Watcher (poll) → Render (cmark-gfm + chroma) → Store (HTML per tab)
           → SSE ping "changed" → Elm viewer fetches GET /content → re-renders
```

**Server** — Elixir, `server/lib/claudeview/` (Bandit + Plug + Jason, no Phoenix):

| Module | Role |
|---|---|
| `application.ex` | Supervises Store, Watcher, Bandit. All config is env vars, read here. |
| `watcher.ex` | Polls `WATCH_DIR/*.md` by `{mtime, size}`; renders changed files into the Store. Polling (not inotify) is deliberate — it works over NFS. |
| `render.ex` | Markdown → HTML via the `cmark-gfm` CLI, then transforms each fenced block: `mermaid`/`dot`/`svg` → inline SVG (via `mmdr`/`dot`), other known languages → `chroma` highlighting, else verbatim. Relative `<img>` links are routed through `/media`. Every transform is best-effort — a failure falls back to the verbatim block. |
| `store.ex` | GenServer: rendered HTML `%{html, mtime}` per tab + SSE subscribers. A rapid rewrite of a joinable tab (`~summary$`) within `JOIN_WINDOW_S` is joined below the old, not replaced. |
| `router.ex` | HTTP: viewer + assets, `GET /content` (JSON snapshot, sets focus = newest), `GET /events` (SSE), `GET /media/<name>` (author images), `POST /push?tab=`. |

**Client** — Elm, single file `web/src/Main.elm` (`Browser.element`). It never
parses Markdown: the server ships rendered HTML strings, injected via a
`raw-html` custom element (`web/index.html`). SSE is a bare doorbell; the payload
always arrives via `GET /content`. Styling in `web/theme.css` (light/dark).

## Toolchain — never install Elixir/Elm locally

Everything runs in a pinned Docker image via the Makefile. The host needs only
Docker + make (host Elixir is too old — 1.14 vs required 1.15).

```
make check        # full gate: format-check, compile --warnings-as-errors, credo --strict, elm make
make check-fast   # format + shell lint only (the pre-commit hook)
make format       # apply mix format / elm-format / shfmt in place
```

Run the app to eyeball a change: `docker compose build claudeview` then run the
`claudeview-claudeview` image with `-e WATCH_DIR=/content -v <dir>:/content`; the
app image (not the tools image) has `cmark-gfm`, `chroma`, `graphviz`, `mmdr`, `curl`.

Tests: `server/test/` (ExUnit). Run with `... tools sh -c 'cd server && mix test'`.
`mix test` boots the app, so the supervised `Store` is already running — reuse it
with unique tab names rather than `start_supervised` (which collides on the name).

## Config (server env vars — see docs/GUIDE.md "Configuration")

`PORT` `WATCH_DIR` `POLL_MS` `JOIN_WINDOW_S` (120) `JOIN_PATTERN` (`~summary$`)
`CLAUDEVIEW_LABEL` `WEB_DIR` `CLAUDEVIEW_SEED`. `config/config.exs` is intentionally empty.

## Conventions

- Readability first: short, well-named functions; comments explain *why*, not how.
  Functions over methods; files are namespaces. Match the surrounding style.
- Idiomatic Elixir/Elm. Keep dependencies minimal and mature.
- Git: never `git add -A` (stage files individually); `git mv`/`git rm` to keep
  history; many small focused commits; messages complete "If applied, this commit
  will…" with a leading capital and no attribution footer. Work on a branch.
- Always run `make check` (or at least `make format`) before committing.
