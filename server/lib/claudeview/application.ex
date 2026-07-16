defmodule Claudeview.Application do
  @moduledoc "Supervises the content store, the directory watcher and the web server."

  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    alias Claudeview.Config

    port = Config.port()
    watch_dir = Config.watch_dir()
    poll_ms = Config.poll_ms()

    children =
      [
        {Claudeview.Store,
         join_window_s: Config.join_window_s(), join_pattern: Config.join_pattern()}
      ] ++
        watchers(watch_dir, poll_ms) ++
        [{Bandit, plug: Claudeview.Router, port: port}]

    Logger.info("ClaudeView on :#{port}, watching #{watch_dir} every #{poll_ms}ms")
    Supervisor.start_link(children, strategy: :one_for_one, name: Claudeview.Supervisor)
  end

  # One watcher per `WATCH_DIR` spec (colon-separated, each `DIR` or `DIR=TAB`).
  # They share the module, so each child needs a distinct supervisor id; `Watcher`
  # no longer registers a fixed process name, so several can run side by side.
  defp watchers(watch_dir, poll_ms) do
    watch_dir
    |> Claudeview.Watcher.parse_specs()
    |> Enum.with_index()
    |> Enum.map(fn {{dir, tab}, i} ->
      Supervisor.child_spec(
        {Claudeview.Watcher, watch_dir: dir, tab: tab, poll_ms: poll_ms},
        id: {Claudeview.Watcher, i}
      )
    end)
  end
end
