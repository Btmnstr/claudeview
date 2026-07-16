defmodule Claudeview.Store do
  @moduledoc """
  Holds the rendered content of every tab and the set of SSE subscribers.

  A tab is `%{html: String.t(), mtime: integer()}` keyed by name. Any change
  broadcasts `:changed` to every subscribed process, which is all the viewer
  needs to know it should re-fetch `/content`.

  When a *summary* tab (name ending in `~summary`, e.g. `ClaudeView~main~summary`)
  is rewritten within `join_window_s` of its previous write, the new HTML is
  appended below the old instead of replacing it. The Stop hook's settle race can
  write an implementation summary then a final summary moments apart; without the
  join the second would clobber the first before it is read.
  """

  use GenServer

  # Separator between two joined writes. Two cmark-gfm fragments stacked with an
  # <hr> between form valid HTML; each was already highlighted, so no re-render.
  @join "\n<hr class=\"cv-join\">\n"

  # Public API

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def put(tab, html, mtime), do: GenServer.cast(__MODULE__, {:put, tab, html, mtime})

  def drop(tab), do: GenServer.cast(__MODULE__, {:drop, tab})

  def snapshot, do: GenServer.call(__MODULE__, :snapshot)

  @doc "Subscribe the calling process; it receives a bare `:changed` on every change."
  def subscribe, do: GenServer.cast(__MODULE__, {:subscribe, self()})

  # Server

  @impl true
  def init(opts) do
    state = %{
      tabs: %{},
      subs: MapSet.new(),
      join_window_s: Keyword.get_lazy(opts, :join_window_s, &Claudeview.Config.join_window_s/0),
      join_pattern: Keyword.get_lazy(opts, :join_pattern, &Claudeview.Config.join_pattern/0)
    }

    {:ok, state}
  end

  @impl true
  def handle_cast({:put, tab, html, mtime}, state) do
    broadcast(state.subs)
    entry = %{html: merged_html(state, tab, html, mtime), mtime: mtime}
    {:noreply, put_in(state.tabs[tab], entry)}
  end

  def handle_cast({:drop, tab}, state) do
    broadcast(state.subs)
    {:noreply, update_in(state.tabs, &Map.delete(&1, tab))}
  end

  def handle_cast({:subscribe, pid}, state) do
    Process.monitor(pid)
    {:noreply, update_in(state.subs, &MapSet.put(&1, pid))}
  end

  @impl true
  def handle_call(:snapshot, _from, state), do: {:reply, state.tabs, state}

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {:noreply, update_in(state.subs, &MapSet.delete(&1, pid))}
  end

  # The HTML to store for `tab`: a fresh write to a joinable tab within the window
  # is appended below the previous one (see the moduledoc); anything else replaces.
  defp merged_html(state, tab, html, mtime) do
    existing = state.tabs[tab]

    if join?(existing, mtime, tab, state.join_window_s, state.join_pattern) do
      existing.html <> @join <> html
    else
      html
    end
  end

  # Join only a fresh write (strictly newer mtime) to a joinable tab that was
  # last written within the window. The strict `>` keeps a Watcher restart —
  # which re-observes every file at its unchanged mtime — from duplicating content.
  defp join?(nil, _mtime, _tab, _window_s, _pattern), do: false

  defp join?(existing, mtime, tab, window_s, pattern) do
    mtime > existing.mtime and
      mtime - existing.mtime <= window_s and
      Regex.match?(pattern, tab)
  end

  defp broadcast(subs), do: Enum.each(subs, &send(&1, :changed))
end
