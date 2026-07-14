defmodule Claudeview.Application do
  @moduledoc "Supervises the content store, the directory watcher and the web server."

  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    port = env_int("PORT", 4790)
    watch_dir = System.get_env("WATCH_DIR", "content")
    poll_ms = env_int("POLL_MS", 1000)
    join_window_s = env_int("JOIN_WINDOW_S", 120)

    children = [
      {Claudeview.Store, join_window_s: join_window_s, join_pattern: join_pattern()},
      {Claudeview.Watcher, watch_dir: watch_dir, poll_ms: poll_ms},
      {Bandit, plug: Claudeview.Router, port: port}
    ]

    Logger.info("ClaudeView on :#{port}, watching #{watch_dir} every #{poll_ms}ms")
    Supervisor.start_link(children, strategy: :one_for_one, name: Claudeview.Supervisor)
  end

  defp env_int(name, default) do
    case System.get_env(name) do
      nil -> default
      value -> String.to_integer(value)
    end
  end

  # Tab names matching this pattern have rapid rewrites joined rather than
  # replaced. Default: session-shaped names ending in `-<hex>` (e.g. `-7f18`).
  defp join_pattern do
    case System.get_env("JOIN_PATTERN") do
      nil -> ~r/-[0-9a-f]{4,}$/i
      source -> Regex.compile!(source)
    end
  end
end
