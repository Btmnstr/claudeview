# Stage 1 — compile the Elm viewer to a single elm.js.
# Debian (glibc) base: the official Elm binary is not musl-compatible.
FROM node:20-slim AS elm
RUN apt-get update && apt-get install -y curl && rm -rf /var/lib/apt/lists/*
RUN curl -fsSL https://github.com/elm/compiler/releases/download/0.19.1/binary-for-linux-64-bit.gz \
      -o /tmp/elm.gz \
    && gunzip /tmp/elm.gz \
    && chmod +x /tmp/elm \
    && mv /tmp/elm /usr/local/bin/elm
WORKDIR /web
COPY web/elm.json ./
COPY web/src ./src
RUN elm make src/Main.elm --optimize --output=elm.js

# Stage 2 — the Elixir server plus cmark-gfm, serving the compiled assets.
# Debian-based image: cmark-gfm (GFM tables etc.) is packaged there, not on Alpine.
FROM elixir:1.16 AS app
RUN apt-get update \
    && apt-get install -y --no-install-recommends cmark-gfm graphviz curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# chroma — a single static Go binary for syntax highlighting, pinned and fetched
# like the Elm compiler (a build tool, so downloaded rather than vendored).
RUN curl -fsSL https://github.com/alecthomas/chroma/releases/download/v2.14.0/chroma-2.14.0-linux-amd64.tar.gz \
      -o /tmp/chroma.tgz \
    && tar -xzf /tmp/chroma.tgz -C /usr/local/bin chroma \
    && rm /tmp/chroma.tgz \
    && chroma --version

# mmdr — a native Rust Mermaid→SVG renderer (no browser, Node or Puppeteer),
# pinned and fetched like chroma. Renders ```mermaid blocks server-side to inline
# SVG; ```dot blocks go to graphviz above, so no headless browser is needed.
RUN curl -fsSL https://github.com/1jehuang/mermaid-rs-renderer/releases/download/v0.3.1/mmdr-x86_64-unknown-linux-gnu.tar.gz \
      -o /tmp/mmdr.tgz \
    && tar -xzf /tmp/mmdr.tgz -C /usr/local/bin ./mmdr \
    && rm /tmp/mmdr.tgz \
    && mmdr --version
WORKDIR /app
ENV MIX_ENV=prod
RUN mix local.hex --force && mix local.rebar --force
COPY server/mix.exs ./
COPY server/config ./config
RUN mix deps.get --only prod && mix deps.compile
COPY server/lib ./lib
RUN mix compile
COPY web/index.html web/theme.css ./priv/web/
COPY web/JetBrainsMono-Regular.woff2 web/JetBrainsMono-Bold.woff2 ./priv/web/
COPY --from=elm /web/elm.js ./priv/web/elm.js
# The setup guide, seeded into an empty watch dir on first run (see Watcher).
# Outside priv/web, so it is seeded, not served.
COPY content/welcome.md ./priv/welcome.md
ENV WEB_DIR=/app/priv/web \
    WATCH_DIR=/content \
    CLAUDEVIEW_SEED=/app/priv/welcome.md \
    PORT=4790 \
    POLL_MS=1000
EXPOSE 4790
CMD ["mix", "run", "--no-halt"]

# Stage 3 — the code-quality toolchain. `make check` runs the checks inside this
# image, so every machine uses the exact same pinned tool versions regardless of
# what (if anything) is installed on the host. elixir:1.16 gives us mix (format,
# compile, Credo); the three formatters/linters are fetched as single pinned
# binaries, exactly like the Elm compiler and chroma above.
FROM elixir:1.16 AS tools
RUN apt-get update \
    && apt-get install -y --no-install-recommends curl ca-certificates xz-utils make git \
    && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL https://github.com/elm/compiler/releases/download/0.19.1/binary-for-linux-64-bit.gz \
      -o /tmp/elm.gz \
    && gunzip /tmp/elm.gz \
    && chmod +x /tmp/elm \
    && mv /tmp/elm /usr/local/bin/elm
RUN curl -fsSL https://github.com/avh4/elm-format/releases/download/0.8.7/elm-format-0.8.7-linux-x64.tgz \
      | tar -xz -C /usr/local/bin elm-format
RUN curl -fsSL -o /usr/local/bin/shfmt \
      https://github.com/mvdan/sh/releases/download/v3.8.0/shfmt_v3.8.0_linux_amd64 \
    && chmod +x /usr/local/bin/shfmt
RUN curl -fsSL https://github.com/koalaman/shellcheck/releases/download/v0.10.0/shellcheck-v0.10.0.linux.x86_64.tar.xz \
      | tar -xJ -C /usr/local/bin --strip-components=1 shellcheck-v0.10.0/shellcheck

WORKDIR /work
CMD ["make", "check"]
