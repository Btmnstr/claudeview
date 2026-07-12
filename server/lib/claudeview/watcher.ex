defmodule Claudeview.Watcher do
  @moduledoc """
  Polls `WATCH_DIR` for `*.md` files by modification time and keeps the store in
  sync. Polling (rather than inotify) is deliberate: it is simpler and works over
  NFS, so the same code serves a local directory and a home-lab mount.
  """

  use GenServer
  require Logger

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    dir = Keyword.fetch!(opts, :watch_dir)
    poll_ms = Keyword.get(opts, :poll_ms, 1000)
    File.mkdir_p!(dir)
    {:ok, scan(%{dir: dir, poll_ms: poll_ms, seen: %{}})}
  end

  @impl true
  def handle_info(:poll, state), do: {:noreply, scan(state)}

  # Render new/changed files, drop deleted ones, then schedule the next poll.
  defp scan(state) do
    current =
      for path <- Path.wildcard(Path.join(state.dir, "*.md")), into: %{} do
        {path, mtime(path)}
      end

    for {path, mtime} <- current, Map.get(state.seen, path) != mtime do
      Claudeview.Store.put(tab_name(path), Claudeview.Render.to_html(path), mtime)
    end

    for {path, _} <- state.seen, not Map.has_key?(current, path) do
      Claudeview.Store.drop(tab_name(path))
    end

    Process.send_after(self(), :poll, state.poll_ms)
    %{state | seen: current}
  end

  defp mtime(path) do
    case File.stat(path, time: :posix) do
      {:ok, %File.Stat{mtime: mtime}} -> mtime
      {:error, _} -> nil
    end
  end

  defp tab_name(path), do: Path.basename(path, ".md")
end
