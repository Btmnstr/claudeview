defmodule Claudeview.Render do
  @moduledoc """
  Renders a Markdown file to HTML via the `cmark-gfm` CLI.

  GitHub-Flavored-Markdown extensions are enabled explicitly — plain CommonMark
  has no tables, strikethrough or task lists, so those would otherwise pass
  through as literal text.
  """

  @extensions ~w(table strikethrough autolink tasklist)

  def to_html(path) do
    args = Enum.flat_map(@extensions, &["-e", &1]) ++ [path]

    case System.cmd("cmark-gfm", args) do
      {html, 0} -> html
      {err, _} -> "<pre>cmark-gfm failed:\n#{err}</pre>"
    end
  rescue
    _ -> "<pre>cmark-gfm is not installed on the server.</pre>"
  end
end
