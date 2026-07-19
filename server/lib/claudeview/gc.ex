defmodule Claudeview.Gc do
  @moduledoc """
  The filesystem side of "Clear old": delete named documents and sweep collapsed
  directories down to a keep-depth.

  These are pure disk operations — no Store, no HTTP — so the caller wires the
  in-memory drop and the response while this stays trivial to test against a temp
  directory. The viewer decides *what* is stale (it alone knows the grouping and
  which documents are starred); this only carries out the removal.
  """

  @doc """
  Delete `<dir>/<name>.md` for each name, from whichever of `dirs` holds it, and
  return the names actually removed (a name with no matching file is skipped). The
  caller is expected to have sanitized each name against path traversal.
  """
  @spec remove([String.t()], [Path.t()]) :: [String.t()]
  def remove(names, dirs), do: Enum.filter(names, &remove_one(&1, dirs))

  defp remove_one(name, dirs) do
    case Enum.find(dirs, fn dir -> File.exists?(Path.join(dir, name <> ".md")) end) do
      nil -> false
      dir -> File.rm(Path.join(dir, name <> ".md")) == :ok
    end
  end

  @doc """
  In each directory, delete all but the newest `keep` `*.md` files, and return how
  many were removed. Used for the plan-mode directories, whose old drops pile up
  invisibly behind a single collapsed tab — pure newest-N hygiene, no star logic.
  """
  @spec sweep([Path.t()], non_neg_integer()) :: non_neg_integer()
  def sweep(dirs, keep) do
    dirs
    |> Enum.flat_map(&stale_in(&1, keep))
    |> Enum.count(&(File.rm(&1) == :ok))
  end

  defp stale_in(dir, keep) do
    Path.join(dir, "*.md")
    |> Path.wildcard()
    |> Enum.sort_by(&mtime/1, :desc)
    |> Enum.drop(keep)
  end

  defp mtime(path) do
    case File.stat(path, time: :posix) do
      {:ok, %File.Stat{mtime: mtime}} -> mtime
      {:error, _} -> 0
    end
  end
end
