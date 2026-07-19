defmodule Claudeview.Config do
  @moduledoc """
  Every runtime setting, read from the environment in one place.

  `config/config.exs` is intentionally empty: the server takes all of its
  configuration from environment variables, so the same image runs unchanged in
  local dev, a container and the home lab. Centralizing the reads here keeps each
  default in a single spot rather than duplicated across the modules that use it.
  """

  @default_watch_dir "content"
  @default_web_dir "priv/web"

  # The auto-generated `~summary` tab, whose Stop-hook settle race can write twice
  # moments apart, is the one tab whose rapid rewrites join rather than replace.
  @default_join_pattern ~r/~summary$/

  @spec port() :: integer()
  def port, do: env_int("PORT", 4790)

  @spec poll_ms() :: integer()
  def poll_ms, do: env_int("POLL_MS", 1000)

  @spec join_window_s() :: integer()
  def join_window_s, do: env_int("JOIN_WINDOW_S", 120)

  @doc "How many documents a tab-group keeps when \"Clear old\" prunes it. The client
  sends its own value; this is the server-side fallback and the plan-dir sweep's default."
  @spec keep_per_group() :: integer()
  def keep_per_group, do: env_int("KEEP_PER_GROUP", 10)

  @doc "Raw `WATCH_DIR` (colon-separated specs); parse with `Watcher.parse_specs/1`."
  @spec watch_dir() :: String.t()
  def watch_dir, do: System.get_env("WATCH_DIR", @default_watch_dir)

  @doc "Directory the viewer's `index.html`, `elm.js`, `theme.css` and fonts are served from."
  @spec web_dir() :: String.t()
  def web_dir, do: System.get_env("WEB_DIR", @default_web_dir)

  @doc "Host-facing label for a plain watch dir, or nil (the container only sees `/content`)."
  @spec label() :: String.t() | nil
  def label, do: System.get_env("CLAUDEVIEW_LABEL")

  @doc "Markdown file seeded into an empty watch dir on first run, or nil when unset."
  @spec seed() :: String.t() | nil
  def seed, do: System.get_env("CLAUDEVIEW_SEED")

  @doc """
  Tab-name pattern whose rapid rewrites are joined below the previous write rather
  than replacing it. Defaults to the `~summary` tab; override with `JOIN_PATTERN`.
  """
  @spec join_pattern() :: Regex.t()
  def join_pattern do
    case System.get_env("JOIN_PATTERN") do
      nil -> @default_join_pattern
      source -> Regex.compile!(source)
    end
  end

  @spec env_int(String.t(), integer()) :: integer()
  defp env_int(name, default) do
    case System.get_env(name) do
      nil -> default
      value -> String.to_integer(value)
    end
  end
end
