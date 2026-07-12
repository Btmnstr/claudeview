defmodule Claudeview.Store do
  @moduledoc """
  Holds the rendered content of every tab and the set of SSE subscribers.

  A tab is `%{html: String.t(), mtime: integer()}` keyed by name. Any change
  broadcasts `:changed` to every subscribed process, which is all the viewer
  needs to know it should re-fetch `/content`.
  """

  use GenServer

  # Public API

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  def put(tab, html, mtime), do: GenServer.cast(__MODULE__, {:put, tab, html, mtime})

  def drop(tab), do: GenServer.cast(__MODULE__, {:drop, tab})

  def snapshot, do: GenServer.call(__MODULE__, :snapshot)

  @doc "Subscribe the calling process; it receives a bare `:changed` on every change."
  def subscribe, do: GenServer.cast(__MODULE__, {:subscribe, self()})

  # Server

  @impl true
  def init(_), do: {:ok, %{tabs: %{}, subs: MapSet.new()}}

  @impl true
  def handle_cast({:put, tab, html, mtime}, state) do
    broadcast(state.subs)
    {:noreply, put_in(state.tabs[tab], %{html: html, mtime: mtime})}
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

  defp broadcast(subs), do: Enum.each(subs, &send(&1, :changed))
end
