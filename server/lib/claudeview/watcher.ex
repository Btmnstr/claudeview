defmodule Claudeview.Watcher do
  @moduledoc """
  Polls a watched directory for `*.md` files by modification time and keeps the
  store in sync. Polling (rather than inotify) is deliberate: it is simpler and
  works over NFS, so the same code serves a local directory and a home-lab mount.

  A watcher runs in one of two modes. Without `:tab` it mirrors every `*.md` as
  its own tab (name = filename stem). With `:tab` it collapses the directory to a
  single tab of that name showing only the newest file — used for the plan-mode
  directory, where each session drops a fresh, randomly-named plan file but only
  the latest is worth a tab.
  """

  use GenServer
  require Logger

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc """
  Parse a colon-separated `WATCH_DIR` into `{dir, tab | nil}` specs. Each entry is
  `DIR` (one tab per file) or `DIR=TAB` (the directory collapsed to a single tab).
  """
  def parse_specs(watch_dir) do
    watch_dir
    |> String.split(":", trim: true)
    |> Enum.map(fn entry ->
      case String.split(entry, "=", parts: 2) do
        [dir] -> {dir, nil}
        [dir, tab] -> {dir, tab}
      end
    end)
  end

  @impl true
  def init(opts) do
    dir = Keyword.fetch!(opts, :watch_dir)
    tab = Keyword.get(opts, :tab)
    poll_ms = Keyword.get(opts, :poll_ms, 1000)
    File.mkdir_p!(dir)
    if is_nil(tab), do: maybe_seed(dir)
    {:ok, scan(%{dir: dir, tab: tab, poll_ms: poll_ms, seen: %{}})}
  end

  # A fresh watch dir shows nothing; drop the welcome/setup guide in so a new
  # server greets you with the remaining steps. Only when no `*.md` exists yet, so
  # your own content is never clobbered (it reappears only if you empty the
  # directory again). `CLAUDEVIEW_SEED` points at the image-baked copy; unset
  # (local dev, whose default `content/` already holds it) means no seed.
  defp maybe_seed(dir) do
    seed = Claudeview.Config.seed()

    if seed && File.exists?(seed) && Path.wildcard(Path.join(dir, "*.md")) == [] do
      case File.cp(seed, Path.join(dir, Path.basename(seed))) do
        :ok -> Logger.info("Seeded #{dir} with #{Path.basename(seed)}")
        {:error, reason} -> Logger.warning("Could not seed #{dir}: #{inspect(reason)}")
      end
    end
  end

  @impl true
  def handle_info(:poll, state), do: {:noreply, scan(state)}

  # Sync the store, then schedule the next poll. `seen` is the `%{path => stamp}`
  # this pass observed, whichever mode produced it.
  defp scan(state) do
    seen = if state.tab, do: sync_collapsed(state), else: sync_per_file(state)
    Process.send_after(self(), :poll, state.poll_ms)
    %{state | seen: seen}
  end

  # Mirror every `*.md` as its own tab; drop tabs whose file has vanished.
  defp sync_per_file(state) do
    current =
      for path <- Path.wildcard(Path.join(state.dir, "*.md")), into: %{} do
        {path, stat(path)}
      end

    for {path, {mtime, _size} = stamp} <- current, Map.get(state.seen, path) != stamp do
      Claudeview.Store.put(tab_name(path), Claudeview.Render.to_html(path), mtime)
    end

    for {path, _} <- state.seen, not Map.has_key?(current, path) do
      Claudeview.Store.drop(tab_name(path))
    end

    current
  end

  # Collapse the directory to `state.tab`, tracking only the newest `*.md`. When a
  # newer file appears (a new plan-mode session) the tab switches to it; when the
  # directory empties, the tab is dropped.
  defp sync_collapsed(state) do
    newest =
      Path.join(state.dir, "*.md")
      |> Path.wildcard()
      |> Enum.map(fn path -> {path, stat(path)} end)
      |> Enum.filter(fn {_path, {mtime, _size}} -> mtime end)
      |> Enum.max_by(fn {_path, {mtime, _size}} -> mtime end, fn -> nil end)

    case newest do
      nil ->
        if state.seen != %{}, do: Claudeview.Store.drop(state.tab)
        %{}

      {path, {mtime, _size} = stamp} ->
        if Map.get(state.seen, path) != stamp do
          Claudeview.Store.put(state.tab, Claudeview.Render.to_html(path), mtime)
        end

        %{path => stamp}
    end
  end

  # `{mtime, size}` rather than bare mtime: POSIX mtime is seconds-resolution, so
  # a rewrite in the same second shares its mtime; the size closes that gap and
  # keeps a same-second edit from being skipped as unchanged.
  defp stat(path) do
    case File.stat(path, time: :posix) do
      {:ok, %File.Stat{mtime: mtime, size: size}} -> {mtime, size}
      {:error, _} -> {nil, nil}
    end
  end

  defp tab_name(path), do: Path.basename(path, ".md")
end
