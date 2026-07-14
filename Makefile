# ClaudeView — code-quality tool chain.
#
# Every check runs inside the "tools" Docker image (see Dockerfile / compose),
# so the versions are pinned and identical on every machine — the host needs
# only Docker and make, never Elixir/Elm/shellcheck/etc. locally.
#
# One-time setup:
#   make tools          build the image and warm hex/rebar/deps
#   make install-hooks  run the checks automatically on commit and push (opt-in)
#
# Day to day:
#   make format         apply every formatter in place
#   make check          the full gate: format, compile, type-check, lint
#   make check-fast     format + shell lint only (what the pre-commit hook runs)
#
# The public targets dispatch into the container; the _prefixed targets are the
# real commands, run there (or on any host that has the tools).

.DEFAULT_GOAL := help

# Run a target inside the tools image, as the invoking user (so files written by
# the formatters stay owned by you). HOME lands on the mounted tree so the mix,
# hex and elm caches persist across runs under .tools/ (gitignored).
RUN := docker compose run --rm \
         --user $(shell id -u):$(shell id -g) \
         -e HOME=/work/.tools/home \
         tools

# Every hand-written shell script, formatted and linted as a set.
SHELL_FILES := bin/claudeview-open hooks/claudeview-push \
               githooks/pre-commit githooks/pre-push

.PHONY: help
help:
	@echo 'targets: tools  format  check  check-fast  install-hooks'
	@echo 'first run: make tools && make install-hooks'

# --- public: dispatch into the container ------------------------------------

.PHONY: format check check-fast
format:     ; $(RUN) make _format
check:      ; $(RUN) make _check
check-fast: ; $(RUN) make _check-fast

.PHONY: tools
tools:
	docker compose build tools
	$(RUN) sh -c 'mix local.hex --force && mix local.rebar --force && cd server && mix deps.get'

.PHONY: install-hooks
install-hooks:
	git config core.hooksPath githooks
	@echo "Hooks enabled. Disable with: git config --unset core.hooksPath"

# --- inside the container: the actual commands -------------------------------

.PHONY: _format
_format:
	cd server && mix format
	elm-format --yes web/src
	shfmt -w -i 2 -ci $(SHELL_FILES)

# Fast enough for every commit: formatting and shell lint, no compile.
.PHONY: _check-fast
_check-fast:
	cd server && mix format --check-formatted
	elm-format --validate web/src
	shellcheck $(SHELL_FILES)
	shfmt -d -i 2 -ci $(SHELL_FILES)

# The full gate: adds compilation, Elm's type check and Credo.
.PHONY: _check
_check: _check-fast
	cd server && mix deps.get
	cd server && mix compile --warnings-as-errors
	cd server && mix credo --strict
	cd web && elm make src/Main.elm --output=/dev/null
