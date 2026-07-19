# ClaudeView guide

Everything past the [README](../README.md)'s pitch and quick start: platform
setup, the ergonomics of living with a second screen, the full configuration
reference, and how to work on the code.

## Setup

### Windows (WSL2)

The hooks are bash + `jq` + `curl`, so on Windows **run Claude Code itself inside
WSL2** — then ClaudeView behaves exactly as on Linux, and the README's quick
start, hook wiring and permissions all apply unchanged:

- Check out ClaudeView inside the WSL2 distro and run Claude Code from there, so
  the hooks execute in a shell that has `jq`/`curl` and a valid `$HOME`.
- Docker Desktop with the WSL2 backend (or Docker installed inside the distro)
  runs the server; the published port is reachable at `http://localhost:4790`
  from the Windows host.
- Open the viewer in a **Windows-side** browser — `bin/claudeview-open` looks for a
  Linux browser and won't help inside WSL, so use an ordinary window or a Windows
  shortcut to the URL. Rotate to portrait in Windows Display settings.

Native Windows (no WSL) is not supported: `docker-compose.yml` interpolates
`${HOME}` for its bind mounts, which is unset outside WSL (Windows uses
`USERPROFILE`). Inside WSL `$HOME` is set, so the compose file works as written.

### Approve the writes once

The README shows the one rule to add — `"Edit(~/.claudeview/**)"` under
`permissions.allow`. This is why it is shaped that way.

One `Edit` rule is enough: file-permission checks only honor `Edit(path)` rules,
and an `Edit` rule covers **all** file-editing tools (Write, Edit, NotebookEdit).
A separate `Write(...)` rule is inert — Claude warns that it is not matched — so
don't add one. `**` covers every file under the directory.

Put it in `~/.claude/settings.json` rather than a project's own settings: user
scope applies to every project, which is what you want, since `~/.claudeview` is
shared by all of them.

If you point the viewer elsewhere with `CLAUDEVIEW_DIR`, match that path instead
— a leading `//` denotes an absolute path, e.g. `Edit(//mnt/nfs/claudeview/**)`.

### Hook delivery: file or HTTP

By default the hook writes to **`~/.claudeview`** — the same directory the
container watches — so no environment variable is required. To send elsewhere,
set one of:

- `CLAUDEVIEW_DIR=/some/dir` — write `<tab>.md` there instead (also update the
  compose mount if you want the server to watch it).
- `CLAUDEVIEW_URL=http://host:4790` — HTTP `POST` (remote / home-lab).

The script uses a 2-second curl timeout and always exits 0, so a viewer that is
down never blocks Claude.

The plan hook is wired to **`PreToolUse`** rather than `PostToolUse` deliberately:
it mirrors a plan *before* you approve it, so you read it on the big screen while
deciding. `PostToolUse` would fire only after approval — too late to help.

What the `Stop` hook chooses to mirror — and what it deliberately skips — is
covered under [Limitations](#limitations); `CLAUDEVIEW_MIN_CHARS` and
`CLAUDEVIEW_SETTLE` tune it (see [Hook environment](#hook-environment)).

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

### Start the viewer on login

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

### When nothing appears

Every hook run appends its outcome — written / skipped / POST failed — to
`~/.claudeview/.push.log`, so a viewer that stays dark is one `tail` away from an
explanation:

```sh
tail ~/.claudeview/.push.log        # override the path with CLAUDEVIEW_LOG
```

Hooks are read at session start, so a hook you just wired up does nothing until
you open a **new** Claude Code session.

## Usage tips

### Portrait monitor

Rotate the target monitor to portrait at the OS level, **not** in the browser:

```sh
xrandr --output DP-0 --rotate left        # X11 (use your output's name)
wlr-randr --output DP-0 --transform 90    # Wayland (wlroots)
```

On macOS rotate under **System Settings › Displays**, on Windows under **Display
settings › Display orientation** — there is no command-line equivalent to script.

### Placing the window

`bin/claudeview-open` places the window at `0,0` by default; set
`CLAUDEVIEW_POS="x,y"` to target a monitor that sits elsewhere in your layout.

It takes the first Chromium-family browser it finds: `google-chrome`,
`google-chrome-stable`, `chromium`, `chromium-browser` or `brave-browser` on
`PATH`, then the fixed `/Applications` bundle paths for Chrome, Chromium, Brave
and Edge (on macOS those are never on `PATH`). The family is not a preference —
the script needs `--app` for the chromeless window and `--window-position` to land
it on the right monitor, and Firefox offers neither. If Firefox is your browser,
open `http://localhost:4790` in an ordinary window and full-screen it by hand;
the viewer itself works the same.

### Pinning holds your place

By default each content change re-adopts the server's focus (the newest-modified
doc), so a busy session can pull the view away mid-read. Click the **📌** at the
body's top-left to pin the current document, or just scroll off the top — that
pins automatically and releases when you scroll back. While pinned, a group that
gains a new document shows a small **red dot**; click the group to open it, which
clears the dot.

### Starring a document as a reference

The **⭐** just below the pin marks the current document as a *reference*. A
starred document carries a ★ in its group's dropdown, so a plan, design doc or
research note you keep coming back to stays easy to pick out among the churnier
`summary` output around it. The mark is purely manual — unlike the pin it never
moves on its own — and it lives for the life of the viewer page (a reload starts
fresh). Its second job is protection: **"Clear old" never deletes a starred
document** (see below).

### Downloading a document

The **⬇** at the top-right hands you the document's *raw Markdown* — the original
source the server rendered, not the HTML on screen — as a `.md` file download. The
watched directory is best treated as a scratch of temporary copies (see the next
section), so this is how you lift a plan or review out of it and keep it somewhere
permanent.

### Clearing old documents

The tabs in the viewer are **temporary copies**: the hook and your `Write`s drop
Markdown into the watched directory and it accumulates. **"Clear old"** in the
header is the housekeeping for that — but be clear on what it does:

> It **permanently deletes** the underlying `.md` files from the watched
> directory. This is a real removal, not just hiding tabs — the tab and its file
> both go, and there is no undo.

That is safe *because* those files are throwaway: the durable version of the work
lives in your repo, the plan file, or the Claude Code transcript. But if a document
in there is the only copy of something you want, **download it first**.

What it keeps:

- Each repo group is pruned to its **newest ten** documents; older ones are
  deleted.
- **Starred documents are always kept**, and count toward the ten — so a starred
  reference survives a cull of newer, disposable output.
- The collapsed plan directory is swept to the same depth, clearing the old plan
  files that pile up invisibly behind the single `plan (live)` tab.

Since a starred document's protection is only as good as the viewer's *current*
star state (stars reset on reload), re-star what matters before a big clear. The
button takes **two clicks** — it arms into a red **Delete N** beside a yellow
**Cancel**, so a one-way delete never fires on a stray click — and it hides
entirely when there is nothing old enough to remove.

### Tabs and session grouping

The hook names each tab **`<repo>~<branch>~<doc>`**: the git repo (a bare-repo +
worktree layout reports the repo, not the branch-named worktree), the checked-out
branch, and the kind of document. Outside a repo the session is `<topic>~<sid>`,
so same-directory sessions stay apart.

The viewer folds those into **one split-button per repo**, keyed on the first
`~`-segment and matched case-insensitively (`SimNavLog` and `simnavlog` are one
group). The button jumps to that repo's newest document and the caret reaches the
rest — so a repo's `plan`, `summary` and manual docs sit together across *all* its
branches, rather than fragmenting into a group per branch. The branch moves into
the dropdown labels, shown only when a repo has more than one branch in play.

The `~` delimiter is reserved: git forbids it in branch names, and each component
is sanitized, so a repo or branch containing hyphens never mis-splits. A name with
no `~` at all falls back to the older rule — the segment before the first `-` — so
tabs written before the `~` grammar still group.

Manual `Write`s reuse the exact key via `bin/claudeview-session`; outside a git
repo it prints just the directory name, so supply your own `<intention>~<doc>` in
that case.

### Diagrams and images

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

## Remote / home lab

Nothing here is local-only:

1. Deploy the same image to the home-lab Docker host.
2. Point `WATCH_DIR` at an NFS-mounted content path
   (`WATCH_DIR=/mnt/nfs/claudeview`). mtime polling works over NFS by design.
   `WATCH_DIR` is colon-separated, so a local directory and an NFS mount (or the
   plan-mode `plan` tab) coexist — e.g. `WATCH_DIR=/mnt/nfs/claudeview:/content`.
3. On the Claude Code host, set `CLAUDEVIEW_URL=http://homelab:4790` so hooks
   `POST` over the network — **or** write straight to the NFS mount with
   `CLAUDEVIEW_DIR`. Both feed the same watcher.

## Reference

### Configuration

Server environment variables:

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

### Hook environment

Set on the machine running Claude Code:

| Env var | Default | Meaning |
|---|---|---|
| `CLAUDEVIEW_DIR` | `~/.claudeview` | Directory the hook writes `<tab>.md` into (file-delivery mode). |
| `CLAUDEVIEW_URL` | *(unset)* | If set, the hook `POST`s to `<url>/push` instead of writing a file (remote / home-lab). |
| `CLAUDEVIEW_MIN_CHARS` | `200` | Floor for `last-message`; shorter final blocks are skipped. |
| `CLAUDEVIEW_SID_CHARS` | `4` | Length of the session-id used as the branch stand-in for **non-git** sessions (`<topic>~<sid>`), so same-directory sessions stay apart; `0` drops it. Git sessions key on the branch and ignore it. |
| `CLAUDEVIEW_SETTLE` | `0.5` | Seconds `last-message` waits before reading the transcript, to let the turn's final block flush. `0` disables. |
| `CLAUDEVIEW_LOG` | `~/.claudeview/.push.log` | Breadcrumb log each invocation's outcome is appended to. |

### Launcher environment

Set on the viewer machine, for `bin/claudeview-open`:

| Env var | Default | Meaning |
|---|---|---|
| `CLAUDEVIEW_URL` | `http://localhost:4790` | Viewer URL the browser window opens. |
| `CLAUDEVIEW_POS` | `0,0` | Window position `x,y` (target a monitor elsewhere in the layout). |
| `CLAUDEVIEW_PROFILE` | `~/.claudeview-profile` | Dedicated browser profile dir, kept separate from your everyday browser. |

### Endpoints

| Method | Path | Purpose |
|---|---|---|
| `GET` | `/` | The Elm viewer. |
| `GET` | `/assets/<name>` | Static assets (`elm.js`, `theme.css`, webfonts). |
| `GET` | `/events` | SSE stream; emits `data: changed` on any content change (and once on connect). |
| `GET` | `/content` | JSON snapshot: `{tabs: [{name, html, mtime}], focus, watching: [dir, …]}`. |
| `GET` | `/media/<name>` | An image file from `WATCH_DIR`, for Markdown `![alt](name.png)`. |
| `GET` | `/download/<name>` | The tab's raw Markdown, as a file download (`Content-Disposition: attachment`). |
| `POST` | `/push?tab=<name>` | Write the request body to `<name>.md` in `WATCH_DIR`. |
| `POST` | `/clear-old` | Prune (delete) stale documents — see [Clearing old documents](#clearing-old-documents). Body `{"delete": [names], "keep": n}`: the viewer sends the exact stale list plus its keep-depth, and the server also sweeps each collapsed directory to its newest `keep` files. |

## Development

### Project layout

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
| `Makefile` / `githooks/` | The code-quality tool chain and its opt-in git hooks. |
| `AGENTS.md` | Architecture and conventions, oriented at an AI assistant — but the shortest tour of the internals for a human too. |

### The check gate

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

## Limitations

- **`last-message` skips short turns** by design: a turn whose last text block is
  under `CLAUDEVIEW_MIN_CHARS` (or which emits no prose at all) produces no tab,
  so trivial acknowledgements never clobber the last long answer you were reading.
- **`last-message` mirrors the turn's *last* text block.** A turn almost always
  *ends* with a tool call, so the hook takes the last **text** block rather than
  the last message — faithful to what ended on screen, but that can be a short
  procedural lead-in ("let me update the plan…") rather than the substantial
  summary above it. `CLAUDEVIEW_SETTLE` eases the related flush race; writing the
  file yourself avoids both.
- **Rendering treats content as trusted** (local files / your own Claude
  sessions): `cmark-gfm` output and `chroma`'s highlighted spans are injected
  as-is. For untrusted input, enable `cmark-gfm`'s `tagfilter` extension in
  `server/lib/claudeview/render.ex`.
