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
    && apt-get install -y --no-install-recommends cmark-gfm \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /app
ENV MIX_ENV=prod
RUN mix local.hex --force && mix local.rebar --force
COPY server/mix.exs ./
COPY server/config ./config
RUN mix deps.get --only prod && mix deps.compile
COPY server/lib ./lib
RUN mix compile
COPY web/index.html web/theme.css ./priv/web/
COPY --from=elm /web/elm.js ./priv/web/elm.js
ENV WEB_DIR=/app/priv/web \
    WATCH_DIR=/content \
    PORT=4790 \
    POLL_MS=1000
EXPOSE 4790
CMD ["mix", "run", "--no-halt"]
