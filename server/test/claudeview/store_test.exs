defmodule Claudeview.StoreTest do
  @moduledoc "Exercises the join-vs-replace decision in Store.put/3."

  use ExUnit.Case, async: false

  alias Claudeview.Store

  # The application already supervises a Store started with production defaults
  # (120s window, `~summary$` join pattern). Each test uses a distinct tab name
  # so they stay independent of order and of that shared state.

  # `snapshot/0` is a call, so it flushes the preceding `put/3` casts: reading it
  # after the writes guarantees they have been applied.
  defp html(tab) do
    Store.snapshot()[tab].html
  end

  test "a rapid rewrite of a summary tab is joined below the previous write" do
    Store.put("proj~main~summary", "FIRST", 100)
    Store.put("proj~main~summary", "SECOND", 150)

    assert html("proj~main~summary") =~ ~r/FIRST.*<hr class="cv-join">.*SECOND/s
  end

  test "a rewrite past the window replaces instead of joining" do
    Store.put("proj~dev~summary", "FIRST", 100)
    Store.put("proj~dev~summary", "SECOND", 300)

    assert html("proj~dev~summary") == "SECOND"
  end

  test "a non-summary tab always replaces, even within the window" do
    for tab <- ["welcome", "proj~main~plan", "proj~main~review"] do
      Store.put(tab, "FIRST", 100)
      Store.put(tab, "SECOND", 150)
      assert html(tab) == "SECOND"
    end
  end

  test "an equal mtime replaces — a watcher restart re-observing files must not duplicate" do
    Store.put("proj~equal~summary", "FIRST", 100)
    Store.put("proj~equal~summary", "FIRST", 100)

    assert html("proj~equal~summary") == "FIRST"
  end
end
