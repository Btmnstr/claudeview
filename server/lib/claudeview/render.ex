defmodule Claudeview.Render do
  @moduledoc """
  Renders a Markdown file to HTML via the `cmark-gfm` CLI, then colours fenced
  code blocks with the `chroma` CLI.

  GitHub-Flavored-Markdown extensions are enabled explicitly — plain CommonMark
  has no tables, strikethrough or task lists, so those would otherwise pass
  through as literal text.

  `cmark-gfm` renders a fenced block as `<pre><code class="language-X">…</code></pre>`
  with the code HTML-escaped. For every language we recognise we hand that code
  to `chroma`, which wraps each token in a `<span class="…">`; `theme.css` colours
  those classes. A block with no language, or a language we don't list, is left
  exactly as `cmark-gfm` rendered it.
  """

  @extensions ~w(table strikethrough autolink tasklist)

  # Markdown info-string → chroma lexer. Only these are highlighted; anything
  # else (plain prose, a stray ```console```) passes through unchanged.
  @lexers %{
    "python" => "python",
    "py" => "python",
    "c" => "c",
    "elixir" => "elixir",
    "ex" => "elixir",
    "exs" => "elixir",
    "elm" => "elm",
    "typescript" => "typescript",
    "ts" => "typescript",
    "html" => "html",
    "bash" => "bash",
    "sh" => "bash",
    "shell" => "bash"
  }

  @code_block ~r|<pre><code class="language-([^"]+)">(.*?)</code></pre>|s

  def to_html(path) do
    args = Enum.flat_map(@extensions, &["-e", &1]) ++ [path]

    case System.cmd("cmark-gfm", args) do
      {html, 0} -> highlight(html)
      {err, _} -> "<pre>cmark-gfm failed:\n#{err}</pre>"
    end
  rescue
    _ -> "<pre>cmark-gfm is not installed on the server.</pre>"
  end

  # Replace each recognised code block with its chroma-highlighted form.
  defp highlight(html) do
    Regex.replace(@code_block, html, fn whole, lang, body ->
      case @lexers[String.downcase(lang)] do
        nil -> whole
        lexer -> chroma(lexer, unescape(body)) || whole
      end
    end)
  end

  # chroma reads its input from a file, so the source round-trips through a temp
  # file. A non-zero exit — or a missing chroma — yields nil and the caller keeps
  # the plain block: highlighting is a nicety, never load-bearing.
  defp chroma(lexer, code) do
    path = Path.join(System.tmp_dir!(), "claudeview-#{:erlang.unique_integer([:positive])}")
    File.write!(path, code)

    try do
      args = ["--lexer", lexer, "--html", "--html-only", "--html-tab-width", "2", path]

      case System.cmd("chroma", args, stderr_to_stdout: true) do
        {out, 0} -> out
        _ -> nil
      end
    rescue
      _ -> nil
    after
      File.rm(path)
    end
  end

  # cmark escapes only & < > in code text; unescape so chroma sees the source it
  # expects (and re-escapes itself). The & substitution must come last.
  defp unescape(text) do
    text
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", "\"")
    |> String.replace("&#39;", "'")
    |> String.replace("&amp;", "&")
  end
end
