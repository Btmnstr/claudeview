defmodule Claudeview.GcTest do
  @moduledoc "Exercises the file removal and newest-N sweep behind \"Clear old\"."

  use ExUnit.Case, async: true

  alias Claudeview.Gc

  # A tab's file is `<dir>/<name>.md`, `mtime` giving its age (seconds resolution).
  defp write(dir, name, mtime) do
    path = Path.join(dir, name <> ".md")
    File.write!(path, name)
    File.touch!(path, mtime)
    path
  end

  defp names(dir) do
    Path.join(dir, "*.md")
    |> Path.wildcard()
    |> Enum.map(&Path.basename(&1, ".md"))
    |> Enum.sort()
  end

  @tag :tmp_dir
  test "remove/2 deletes the named files across dirs and reports what it removed", %{tmp_dir: tmp} do
    a = Path.join(tmp, "a")
    b = Path.join(tmp, "b")
    File.mkdir_p!(a)
    File.mkdir_p!(b)
    write(a, "proj~main~plan", 100)
    write(b, "proj~main~note", 100)

    # "proj~main~gone" has no file; it is skipped, not reported as removed.
    removed = Gc.remove(["proj~main~plan", "proj~main~note", "proj~main~gone"], [a, b])

    assert Enum.sort(removed) == ["proj~main~note", "proj~main~plan"]
    assert names(a) == []
    assert names(b) == []
  end

  @tag :tmp_dir
  test "sweep/2 keeps the newest `keep` files and deletes the rest", %{tmp_dir: tmp} do
    for i <- 1..12, do: write(tmp, "plan-#{i}", 1000 + i)

    swept = Gc.sweep([tmp], 10)

    # The two oldest (mtimes 1001, 1002) go; the newest ten stay.
    assert swept == 2
    assert names(tmp) == Enum.sort(for i <- 3..12, do: "plan-#{i}")
  end

  @tag :tmp_dir
  test "sweep/2 keeps everything when a dir holds `keep` or fewer files", %{tmp_dir: tmp} do
    for i <- 1..5, do: write(tmp, "plan-#{i}", 1000 + i)

    assert Gc.sweep([tmp], 10) == 0
    assert length(names(tmp)) == 5
  end
end
