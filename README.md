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
  `chroma`, and pushes an SSE ping; the
  Elm viewer then fetches the current snapshot and re-renders. One rendering
  pipeline, one content store.
- **Each `.md` file in `WATCH_DIR` is a tab**, newest-modified auto-focused. That
  is the whole "Claude controls the viewer" mechanism — Claude just uses the
  `Write` tool it already has. No plugin, no protocol. When a session tab is
  rewritten within `JOIN_WINDOW_S`, its new content is appended below the old
  rather than replacing it, so two quick writes in one turn both survive.
- **The watcher polls file mtimes** rather than using inotify: polling is simpler
  *and* correct over NFS (where inotify is unreliable), so the same code path
  serves a local directory and a home-lab NFS mount.

## Requirements

- **Docker** with the Compose plugin (server dependencies are all contained in
  the image — Elixir, Elm, `cmark-gfm` and `chroma`).
- **`git`, `jq` and `curl`** on the machine running Claude Code — the host
  dependencies used by the hook and the `claudeview-session` helper. `git` needs
  **≥ 2.31** (for `--path-format`); an older git isn't fatal — the session key
  just falls back to the directory name. On macOS `git` and `curl` ship with the
  OS, but `jq` does not (`brew install jq`).
- A **Chromium-family browser** (`google-chrome`, `chromium`, … on Linux; the
  `Google Chrome.app` / `Chromium.app` / `Brave`/`Edge` bundles on macOS) for the
  viewer window; any browser can open the URL, but the launch script wants `--app`.

### Windows (WSL2)

The hooks are bash + `jq` + `curl`, so on Windows **run Claude Code itself inside
WSL2** — then ClaudeView behaves exactly as on Linux, and everything below applies
unchanged:

- Check out ClaudeView inside the WSL2 distro and run Claude Code from there, so
  the hooks execute in a shell that has `jq`/`curl` and a valid `$HOME`.
- Docker Desktop with the WSL2 backend (or Docker installed inside the distro)
  runs the server; the published port is reachable at `http://localhost:4790`
  from the Windows host.
- Open the viewer in a **Windows-side** Chrome — `bin/claudeview-open` looks for a
  Linux browser and won't help inside WSL, so use an ordinary window or a Windows
  shortcut to the URL. Rotate to portrait in Windows Display settings.

Native Windows (no WSL) is not supported: `docker-compose.yml` interpolates
`${HOME}` for its bind mounts, which is unset outside WSL (Windows uses
`USERPROFILE`). Inside WSL `$HOME` is set, so the compose file works as written.

## Quick start

```sh
git clone <this-repo> ClaudeView
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

Open the viewer as a dedicated, chromeless, full-screen window:

```sh
bin/claudeview-open
```

The viewer's header shows which directory it is watching and whether the live
connection is up. Prove it works without Claude:

```sh
echo "# Hello" > ~/.claudeview/scratch.md            # a 'scratch' tab appears
curl -X POST 'http://localhost:4790/push?tab=note' \
     --data-binary '# Pushed over HTTP'              # a 'note' tab appears
```

### Portrait monitor

Rotate the target monitor to portrait at the OS level (not in the browser):

```sh
xrandr --output DP-0 --rotate left        # X11 (use your output's name)
wlr-randr --output DP-0 --transform 90    # Wayland (wlroots)
```

On macOS rotate under **System Settings › Displays**, on Windows under **Display
settings › Display orientation** — there is no command-line equivalent to script.

`bin/claudeview-open` places the window at `0,0` by default; set
`CLAUDEVIEW_POS="x,y"` to target a monitor that sits elsewhere in your layout.

## Wire up the hooks

Merge `hooks/settings.snippet.json` into `~/.claude/settings.json`, editing the
two absolute paths to point at your checkout. It wires:

- **`PreToolUse` / `ExitPlanMode`** → `claudeview-push plan` — mirrors a plan the
  moment Claude presents it, **before** you approve, so you review it on the big
  screen while deciding. (`PostToolUse` would fire only *after* approval — too
  late.)
- **`Stop`** → `claudeview-push last-message` — mirrors the last block of prose
  Claude leaves on screen at the end of a turn (research, reviews, analysis —
  anything long). A turn almost always *ends* with a tool call, so the hook takes
  the last **text** block of the turn, not the last message. Trivial tails like
  "Done." are skipped: only messages of at least `CLAUDEVIEW_MIN_CHARS`
  characters (default `200`, roughly a paragraph) are mirrored. Because the `Stop`
  event can fire while Claude is still flushing that final block, the hook first
  waits `CLAUDEVIEW_SETTLE` seconds (default `0.5`); this narrows — but cannot
  fully close — a race that otherwise mirrors the preceding lead-in sentence. For
  content that *must* appear, write the file yourself (see the next section).

By default the hook writes to **`~/.claudeview`** — the same directory the
container watches — so no environment variable is required. To send elsewhere,
set one of:

- `CLAUDEVIEW_DIR=/some/dir` — write `<tab>.md` there instead (also update the
  compose mount if you want the server to watch it).
- `CLAUDEVIEW_URL=http://host:4790` — HTTP `POST` (remote / home-lab).

The script uses a 2-second curl timeout and always exits 0, so a viewer that is
down never blocks Claude. Every run appends its outcome (written / skipped / POST
failed) to `~/.claudeview/.push.log` (override with `CLAUDEVIEW_LOG`), so a viewer
that stays dark is one `tail` away from an explanation. Hooks are read at session
start, so open a **new** Claude Code session for them to take effect.

## Let Claude open a tab on purpose

Add a line like this to your project `CLAUDE.md` (or global `~/.claude/CLAUDE.md`):

> To display something on the ClaudeView viewer, write it to
> `~/.claudeview/$(claudeview-session)~<doc>.md`. `claudeview-session` prints this
> session's `<repo>~<branch>` key, so the document groups with the repo's plan
> and summary under one `repo` tab (the branch shows in the doc label). `<doc>`
> names the kind of document —
> `review`, `research`, `notes`. Reuse a stable `<doc>` so an update replaces that
> tab instead of spawning a new one.

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

Outside a git repo it prints just the directory name (there is no branch); supply
your own `<intention>~<doc>` name in that case.

### Approve the writes once, for every session

`~/.claudeview` sits outside your project, so Claude asks before writing there.
Pre-approve it for **all** sessions by adding to `~/.claude/settings.json`
(user scope applies to every project):

```json
{
  "permissions": {
    "allow": [
      "Edit(~/.claudeview/**)"
    ]
  }
}
```

One `Edit` rule is enough: file-permission checks only honor `Edit(path)` rules,
and an `Edit` rule covers **all** file-editing tools (Write, Edit, NotebookEdit).
A separate `Write(...)` rule is inert — Claude warns that it is not matched — so
don't add one. `**` covers every file under the directory. If you point the
viewer elsewhere with `CLAUDEVIEW_DIR`, match that path instead — a leading `//`
denotes an absolute path, e.g. `Edit(//mnt/nfs/claudeview/**)`.

### Watch plan-mode findings live

In plan mode the harness lets Claude write **only** the current plan file
(`~/.claude/plans/<slug>.md`); a `Write` to `~/.claudeview/` is denied. But that
plan file is built incrementally and naturally goes findings → final plan — so
point the viewer at the plans directory, collapsed to a single `plan` tab that
tracks the newest file (`docker-compose.yml` mounts `~/.claude/plans` and sets
`WATCH_DIR=/content:/plans=plan`; see [Configuration](#configuration)). Then add
to `~/.claude/CLAUDE.md`:

> During plan mode the harness lets you write only the designated plan file. Treat
> it as the live ClaudeView document: write your Phase-1 long-form findings into
> the plan file immediately, then overwrite it with the final plan. The `plan` tab
> shows the findings first and the final plan after.

Because each session's plan file has a random name, the directory is collapsed to
one stable tab, shown as **`plan (live)`** — the plan being worked on right now, in
any session, not a project of its own. On ExitPlanMode the `plan` hook files an
attributed `repo~branch~plan` into that session's own group, so the finished plan
sits beside the session's summary; for a moment both show the same content. `plan`
doesn't match `JOIN_PATTERN`, so a rewrite cleanly *replaces* rather than appends.

## Diagrams and images

A tab is Markdown, so beyond prose, tables and highlighted code it can carry
**diagrams** and **images** — both rendered server-side, self-contained, no
browser-side JavaScript.

- **Diagrams** render to inline SVG. Three fenced-block languages are recognised:

  - ` ```mermaid ` — rendered by [`mmdr`](https://github.com/1jehuang/mermaid-rs-renderer),
    a native Rust renderer (no headless browser);
  - ` ```dot ` (or ` ```graphviz `) — rendered by Graphviz `dot`;
  - ` ```svg ` — SVG you authored, passed straight through.

  A block that fails to render — an unknown binary, a syntax error — is left as
  its **verbatim source text**, never a broken image. So the feature is safe to
  lean on: worst case you see the diagram's source.

- **Images** are files you drop into `WATCH_DIR` beside the `.md`, referenced with
  ordinary Markdown: `![alt](shot.png)`. The server serves them from `/media`
  (relative links are rewritten there automatically). Absolute `http(s)://` and
  `data:` URIs are left untouched — note a remote URL is fetched fresh on every
  render, so a local file is the private, offline-friendly choice.

## Start the viewer automatically on login

`docker compose up -d` plus the `restart: unless-stopped` policy already brings
the **server** back after a reboot (as long as Docker starts on boot). To bring
the **browser window** up automatically too, register the launch script with your
OS's login mechanism.

**Linux** — add an XDG autostart entry, `~/.config/autostart/claudeview.desktop`:

```ini
[Desktop Entry]
Type=Application
Name=ClaudeView
Exec=/path/to/ClaudeView/bin/claudeview-open
X-GNOME-Autostart-enabled=true
```

(Adjust the path to your checkout. Most desktop environments read this location;
some use their own autostart mechanism instead.)

**macOS** — add a `launchd` LaunchAgent, `~/Library/LaunchAgents/com.claudeview.open.plist`,
then `launchctl load` it (or just log out and back in):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.claudeview.open</string>
  <key>ProgramArguments</key>
  <array><string>/path/to/ClaudeView/bin/claudeview-open</string></array>
  <key>RunAtLoad</key><true/>
</dict>
</plist>
```

## Roadmap: run the server on the home lab

The prototype runs locally, but nothing is local-only:

1. Deploy the same image to the home-lab Docker host.
2. Point `WATCH_DIR` at an NFS-mounted content path
   (`WATCH_DIR=/mnt/nfs/claudeview`). mtime polling works over NFS by design.
   `WATCH_DIR` is colon-separated, so a local directory and an NFS mount (or the
   plan-mode `plan` tab) coexist — e.g. `WATCH_DIR=/mnt/nfs/claudeview:/content`.
3. On the Claude Code host, set `CLAUDEVIEW_URL=http://homelab:4790` so hooks
   `POST` over the network — **or** write straight to the NFS mount with
   `CLAUDEVIEW_DIR`. Both feed the same watcher.

## Configuration

| Env var | Default | Meaning |
|---|---|---|
| `PORT` | `4790` | HTTP port the server listens on (inside the container). |
| `CLAUDEVIEW_HOST_PORT` | `4790` | Host port `docker compose` publishes the viewer on. |
| `WATCH_DIR` | `content` | Directories the watcher polls, colon-separated. Each entry is `DIR` (one tab per file) or `DIR=TAB` (the directory collapsed to a single `TAB` tracking its newest file). `POST /push` writes to the first directory. Compose sets it to `/content:/plans=plan` — `~/.claudeview` plus a collapsed `plan` tab from `~/.claude/plans`. |
| `CLAUDEVIEW_LABEL` | value of `WATCH_DIR` | Host-facing path shown in the viewer's header (the container only sees `/content`). |
| `POLL_MS` | `1000` | Poll interval in milliseconds. |
| `JOIN_WINDOW_S` | `120` | A joinable tab rewritten within this many seconds of its previous write is *joined* (new content appended below a rule) rather than replaced, so two quick writes don't clobber each other. |
| `JOIN_PATTERN` | `~summary$` | Which tab names join: by default the auto-generated `~summary` tab, whose Stop-hook settle race can write twice. Plan, review and manual docs don't match, so they replace. |
| `WEB_DIR` | `priv/web` | Where `index.html` / `elm.js` / `theme.css` / webfonts are served from. |
| `CLAUDEVIEW_SEED` | *(unset locally; `/app/priv/welcome.md` in the image)* | A Markdown file copied into a per-file watch dir when it holds no `*.md` yet, so a fresh server greets you with the setup guide. Never overwrites existing content; reappears only if you empty the directory again. |

Hook environment variables (set on the machine running Claude Code):

| Env var | Default | Meaning |
|---|---|---|
| `CLAUDEVIEW_DIR` | `~/.claudeview` | Directory the hook writes `<tab>.md` into (file-delivery mode). |
| `CLAUDEVIEW_URL` | *(unset)* | If set, the hook `POST`s to `<url>/push` instead of writing a file (remote / home-lab). |
| `CLAUDEVIEW_MIN_CHARS` | `200` | Floor for `last-message`; shorter final blocks are skipped. |
| `CLAUDEVIEW_SID_CHARS` | `4` | Length of the session-id used as the branch stand-in for **non-git** sessions (`<topic>~<sid>`), so same-directory sessions stay apart; `0` drops it. Git sessions key on the branch and ignore it. |
| `CLAUDEVIEW_SETTLE` | `0.5` | Seconds `last-message` waits before reading the transcript, to let the turn's final block flush. `0` disables. |
| `CLAUDEVIEW_LOG` | `~/.claudeview/.push.log` | Breadcrumb log each invocation's outcome is appended to. |

Launcher environment variables (`bin/claudeview-open`, set on the viewer machine):

| Env var | Default | Meaning |
|---|---|---|
| `CLAUDEVIEW_URL` | `http://localhost:4790` | Viewer URL the browser window opens. |
| `CLAUDEVIEW_POS` | `0,0` | Window position `x,y` (target a monitor elsewhere in the layout). |
| `CLAUDEVIEW_PROFILE` | `~/.claudeview-profile` | Dedicated browser profile dir, kept separate from your everyday browser. |

## Endpoints

| Method | Path | Purpose |
|---|---|---|
| `GET` | `/` | The Elm viewer. |
| `GET` | `/assets/<name>` | Static assets (`elm.js`, `theme.css`, webfonts). |
| `GET` | `/events` | SSE stream; emits `data: changed` on any content change (and once on connect). |
| `GET` | `/content` | JSON snapshot: `{tabs: [{name, html, mtime}], focus, watching: [dir, …]}`. |
| `GET` | `/media/<name>` | An image file from `WATCH_DIR`, for Markdown `![alt](name.png)`. |
| `POST` | `/push?tab=<name>` | Write the request body to `<name>.md` in `WATCH_DIR`. |

## Project layout

| Path | What it is |
|---|---|
| `server/` | Elixir app (Bandit + Plug + Jason). Watches `WATCH_DIR`, renders via `cmark-gfm` (GFM tables, task lists, …), highlights fenced code via `chroma`, renders `mermaid`/`dot`/`svg` blocks to inline SVG (`mmdr`/`graphviz`), serves SSE + the viewer. |
| `web/` | Elm viewer (`Main.elm`) + `index.html` bootstrap + `theme.css` (light/dark palettes, syntax colours) + the bundled JetBrains Mono webfont (`*.woff2`, SIL OFL). |
| `hooks/claudeview-push` | Bash + jq + curl. Mirrors plans / final answers to the viewer. |
| `hooks/claudeview-lib.sh` | Shared identity helpers (`repo~branch` session key), sourced by the hook and `claudeview-session`. |
| `hooks/settings.snippet.json` | Hook wiring to merge into `~/.claude/settings.json`. |
| `bin/claudeview-open` | Opens the viewer as a dedicated, full-screen browser window. |
| `bin/claudeview-session` | Prints this directory's session key, so a manual `Write` groups with the hook's tabs. |
| `content/welcome.md` | The setup guide, baked into the image and auto-seeded into an empty watch dir on first run (`CLAUDEVIEW_SEED`). The live `WATCH_DIR` is `~/.claudeview`, not this folder. |
| `Dockerfile` / `docker-compose.yml` | Contained build (Elm + Elixir + cmark-gfm + chroma + graphviz + mmdr), plus the `tools` stage that runs the checks below. |
| `Makefile` / `githooks/` | The code-quality tool chain and its opt-in git hooks (see Development). |

## Development

Formatting, linting and type checking all run **inside a pinned Docker image**
(the `tools` stage), so the host needs only Docker and `make` — no local Elixir,
Elm or shellcheck, and no version drift between machines.

```sh
make tools          # once: build the image, warm the hex/rebar/deps caches
make install-hooks  # once, optional: run the checks on commit and push
make format         # apply every formatter in place
make check          # the full gate — format, compile, type-check, lint
```

What the gate covers, each with its language's canonical tool:

| Language | Format | Static check |
|---|---|---|
| Elixir | `mix format` | `mix compile --warnings-as-errors`, `mix credo --strict` |
| Elm | `elm-format` | `elm make` (the compiler is the type checker) |
| Bash | `shfmt` | `shellcheck` |

The git hooks are opt-in via `core.hooksPath` (set by `make install-hooks`,
undone by `git config --unset core.hooksPath`). `pre-commit` runs the fast half
(`make check-fast`: formatting + shell lint); `pre-push` runs the full
`make check`. Bypass either once with `--no-verify`.

## Notes and limitations

- **Tabs are grouped by session: `<repo>~<branch>`.** The hook names each tab
  `<session>~<doc>`, where the session is `<repo>~<branch>` (the git repo — so a
  bare-repo + worktree layout reports the repo, not the branch-named worktree —
  and the checked-out branch), or `<topic>~<sid>` outside a repo. The viewer
  groups on the session and shows it as `repo@branch`, so a session's `plan`,
  `summary` and manual docs sit under one tab and different branches stay apart.
  The `~` delimiter is reserved: git forbids it in branch names, and each
  component is sanitized, so a repo or branch containing hyphens never mis-splits.
  Manual `Write`s reuse the exact key via `bin/claudeview-session`.
- **`last-message` skips short turns** by design: a turn whose last text block is
  under `CLAUDEVIEW_MIN_CHARS` (or which emits no prose at all) produces no tab,
  so trivial acknowledgements never clobber the last long answer you were reading.
- **`last-message` mirrors the turn's *last* text block** — faithful to what
  ended on screen, but that can be a short procedural lead-in ("let me update the
  plan…") rather than the substantial summary above it. `CLAUDEVIEW_SETTLE` eases
  the related flush race; writing the file yourself avoids both.
- Rendering treats content as trusted (local files / your own Claude sessions):
  `cmark-gfm` output and `chroma`'s highlighted spans are injected as-is. For
  untrusted input, enable `cmark-gfm`'s `tagfilter` extension in
  `server/lib/claudeview/render.ex`.
- **Pinning holds your place across writes.** By default each content change
  re-adopts the server's focus (the newest-modified doc), so a busy session can
  pull the view away mid-read. Click the **📌** at the body's top-left to pin the
  current document, or just scroll off the top — that pins automatically and
  releases when you scroll back. While pinned, a group that gains a new document
  shows a small **red dot**; click the group to open it, which clears the dot.

## Deliberately out of scope

- MCP server (excluded by design; the file convention replaces it).
- Interactive questions / two-way control — this surface only *shows*.
- `mix release` slimming; the prototype runs `mix run --no-halt`.
- A `Write`-matcher hook for `docs/**.md` (easy to add later).

## License

[MIT](LICENSE) © Virtual Void Stockholm AB
