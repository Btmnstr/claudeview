# ClaudeView

A dedicated, auto-updating **broadcast surface** for Claude Code's long-format
output — plans, research findings, code reviews, backlogs, sprint suggestions.

Pin a browser full-screen (ideally portrait) on a second monitor and let it
*show* the latest long content, nicely themed, updating on its own. Your terminal
stays the place you interact; the viewer is where you read.

No MCP and no interactivity: content reaches the viewer automatically via Claude
Code hooks, **plus** a "Claude opens a tab by writing a file" convention.

![The ClaudeView viewer on a portrait monitor beside the editor](screenshot.webp)

## How it works

```
  Claude Code host                          Server (Docker)            Monitor
  ────────────────                          ───────────────            ───────
  hook: ExitPlanMode ─┐                  ┌── Watcher (poll mtimes) ──┐
  hook: Stop ─────────┼─► claudeview-push│      cmark + chroma       │
  Claude Write tool ──┘   (jq+curl)      │           ▼               │
        writes content/<tab>.md  ──local─┼──► Store (tab→html) ──► SSE ─► Elm viewer
        or POST /push?tab=<tab> ──remote─┘                              (kiosk browser,
                                                                         portrait)
```

Three ideas keep it small:

- **Everything is a file in `WATCH_DIR`.** A local hook writes the file directly;
  a remote hook `POST`s and the server writes the file into its own `WATCH_DIR`.
  Either way the watcher renders it with `cmark-gfm`, highlights fenced code with
  `chroma`, and pushes an SSE ping; the Elm viewer then fetches the current
  snapshot and re-renders. One rendering pipeline, one content store.
- **Each `.md` file in `WATCH_DIR` is a tab**, newest-modified auto-focused. That
  is the whole "Claude controls the viewer" mechanism — Claude just uses the
  `Write` tool it already has. No plugin, no protocol.
- **The watcher polls file mtimes** rather than using inotify: polling is simpler
  *and* correct over NFS (where inotify is unreliable), so the same code path
  serves a local directory and a home-lab NFS mount.

A tab is just Markdown, so it carries tables and highlighted code — and
`mermaid`/`dot`/`svg` blocks, which the server renders to inline SVG with no
browser-side JavaScript. A diagram that fails to render degrades to its verbatim
source, never a broken image, so it is safe to lean on. See
[Diagrams and images](docs/GUIDE.md#diagrams-and-images).

## Requirements

- **Docker** with the Compose plugin (server dependencies are all contained in
  the image — Elixir, Elm, `cmark-gfm` and `chroma`).
- **`git`, `jq` and `curl`** on the machine running Claude Code — the host
  dependencies used by the hook and the `claudeview-session` helper. `git` needs
  **≥ 2.31** (for `--path-format`); an older git isn't fatal — the session key
  just falls back to the directory name. On macOS `git` and `curl` ship with the
  OS, but `jq` does not (`brew install jq`).
- A **browser** — any modern one. The viewer is a plain page; only
  `bin/claudeview-open` below is Chromium-specific.

On Windows, run Claude Code itself inside WSL2 — see
[Windows (WSL2)](docs/GUIDE.md#windows-wsl2).

## Quick start

```sh
git clone https://github.com/Btmnstr/claudeview.git ClaudeView
cd ClaudeView
mkdir -p ~/.claudeview                 # the watched dir; create it as you, not root
docker compose up --build -d
```

The container watches **`~/.claudeview`** (the default the hook writes to as well).
Creating it yourself first keeps it owned by you — otherwise Docker creates the
bind-mount path as `root` and the hook can't write to it.

The viewer listens on **port 4790** by default (chosen to dodge the usual
3000/4000 collisions). Override the host port with `CLAUDEVIEW_HOST_PORT`, e.g.
`CLAUDEVIEW_HOST_PORT=5000 docker compose up -d`.

Point any browser at `http://localhost:4790` and you have the viewer. To get a
*dedicated* one — chromeless, full-screen, on its own profile, worth pinning to a
monitor:

```sh
bin/claudeview-open
```

That script needs a Chromium-family browser (`google-chrome`, `chromium`,
`brave-browser`, Edge), because it leans on `--app` for the chromeless window and
`--window-position` to land it on the right monitor — neither of which Firefox
offers. See [Placing the window](docs/GUIDE.md#placing-the-window).

The viewer's header shows which directory it is watching and whether the live
connection is up. Prove it works without Claude:

```sh
echo "# Hello" > ~/.claudeview/scratch.md            # a 'scratch' tab appears
curl -X POST 'http://localhost:4790/push?tab=note' \
     --data-binary '# Pushed over HTTP'              # a 'note' tab appears
```

## Wire up the hooks

Merge `hooks/settings.snippet.json` into `~/.claude/settings.json`, editing the
two absolute paths to point at your checkout. It wires:

- **`PreToolUse` / `ExitPlanMode`** → `claudeview-push plan` — mirrors a plan the
  moment Claude presents it, **before** you approve, so you review it on the big
  screen while deciding.
- **`Stop`** → `claudeview-push last-message` — mirrors the last block of prose
  Claude leaves on screen at the end of a turn (research, reviews, analysis —
  anything long). Trivial tails like "Done." are skipped.

Hooks are read at session start, so open a **new** Claude Code session for them to
take effect. The hook writes to `~/.claudeview` by default, needs no configuration,
and never blocks Claude when the viewer is down. To send it elsewhere see
[Hook delivery](docs/GUIDE.md#hook-delivery-file-or-http); if a tab doesn't show
up, [When nothing appears](docs/GUIDE.md#when-nothing-appears).

## Let Claude open a tab on purpose

Add a line like this to your project `CLAUDE.md` (or global `~/.claude/CLAUDE.md`):

> To display something on the ClaudeView viewer, write it to
> `~/.claudeview/$(claudeview-session)~<doc>.md`. `claudeview-session` prints this
> session's `<repo>~<branch>` key, so the document groups with the repo's plan
> and summary under one `repo` tab (the branch shows in the doc label). `<doc>`
> names the kind of document — `review`, `research`, `notes`. Reuse a stable
> `<doc>` so an update replaces that tab instead of spawning a new one.

Claude then curates the viewer with the ordinary `Write` tool — no MCP. This is
the **most reliable** path: unlike the `Stop` hook it does not depend on session
lifecycle or transcript timing, so it behaves the same in foreground, background
and away sessions.

`claudeview-session` (in `bin/`) shares one identity library with the hook
(`hooks/claudeview-lib.sh`), so a manual write and the hook's own `plan`/`summary`
tabs can never drift into different groups. Symlink it onto your `PATH` once:

```sh
ln -s "$PWD/bin/claudeview-session" ~/.local/bin/
```

`~/.claudeview` sits outside your project, so Claude asks before writing there.
Pre-approve it for **all** sessions by adding to `~/.claude/settings.json`:

```json
{
  "permissions": {
    "allow": [
      "Edit(~/.claudeview/**)"
    ]
  }
}
```

That one `Edit` rule covers Write too — don't add a separate `Write(...)` rule,
it is inert. [Approve the writes once](docs/GUIDE.md#approve-the-writes-once)
explains why, and what to match if you point the viewer elsewhere.

## Documentation

- **[docs/GUIDE.md](docs/GUIDE.md)** — platform setup (WSL2, autostart), usage
  tips (portrait rotation, pinning), diagrams and images, running it on a home
  lab, the full configuration and endpoint reference, and the development gate.
- **[AGENTS.md](AGENTS.md)** — architecture and conventions. Written for an AI
  assistant working in this repo, and the shortest tour of the internals.

## License

[MIT](LICENSE) © Virtual Void Stockholm AB
