defmodule Claudeview.Render do
  @moduledoc """
  Renders a Markdown file to HTML via the `cmark-gfm` CLI, then transforms each
  fenced code block: a diagram language is rendered to inline SVG, a recognised
  programming language is coloured with `chroma`, anything else is left as-is.

  GitHub-Flavored-Markdown extensions are enabled explicitly — plain CommonMark
  has no tables, strikethrough or task lists, so those would otherwise pass
  through as literal text.

  `cmark-gfm` renders a fenced block as `<pre><code class="language-X">…</code></pre>`
  with the code HTML-escaped. That single seam drives everything below:

    * `mermaid` / `dot` / `svg` blocks become an inline `<svg>` (see `@diagram_langs`);
    * a language in `@lexers` is handed to `chroma`, which wraps each token in a
      `<span class="…">` that `theme.css` colours;
    * an unrecognised language — or a renderer that fails — is left exactly as
      `cmark-gfm` produced it. A diagram thus degrades to its verbatim source,
      never to a broken image.
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

  # Info-strings rendered to inline SVG rather than syntax-highlighted. `mermaid`
  # and `dot` shell out to a pinned binary; `svg` is authored SVG we unwrap.
  @diagram_langs ~w(mermaid dot graphviz svg)

  @code_block ~r|<pre><code class="language-([^"]+)">(.*?)</code></pre>|s

  # A relative Markdown image (not http(s), not a data: URI, not already rooted)
  # points at a file the author dropped beside the .md; route it through /media.
  @img_src ~r/(<img[^>]+\bsrc=")(?!https?:|data:|\/)([^"]+)(")/i

  def to_html(path) do
    args = Enum.flat_map(@extensions, &["-e", &1]) ++ [path]

    case System.cmd("cmark-gfm", args) do
      {html, 0} -> html |> route_images() |> render_blocks()
      {err, _} -> "<pre>cmark-gfm failed:\n#{err}</pre>"
    end
  rescue
    _ -> "<pre>cmark-gfm is not installed on the server.</pre>"
  end

  defp route_images(html), do: Regex.replace(@img_src, html, "\\1/media/\\2\\3")

  # Replace each fenced block with its rendered form, or keep it verbatim when no
  # renderer matches or a renderer returns nil (a failure is never load-bearing).
  defp render_blocks(html) do
    Regex.replace(@code_block, html, fn whole, lang, body ->
      render_block(String.downcase(lang), body) || whole
    end)
  end

  defp render_block(lang, body) when lang in @diagram_langs do
    wrap(diagram_svg(lang, unescape(body)))
  end

  defp render_block(lang, body) do
    case @lexers[lang] do
      nil -> nil
      lexer -> chroma(lexer, unescape(body))
    end
  end

  # Wrap a rendered SVG in a themed card; nil (render failed) propagates so the
  # caller falls back to the verbatim block.
  defp wrap(nil), do: nil
  defp wrap(svg), do: ~s(<div class="cv-diagram">\n#{svg}\n</div>)

  # `mermaid`/`dot` render through a pinned binary; `svg` is already SVG we unwrap.
  defp diagram_svg("mermaid", source),
    do: svg_via_files("mmdr", fn i, o -> ["-i", i, "-o", o, "-e", "svg"] end, source)

  defp diagram_svg(lang, source) when lang in ~w(dot graphviz),
    do: svg_via_files("dot", fn i, o -> ["-Tsvg", "-o", o, i] end, source)

  defp diagram_svg("svg", source), do: strip_to_svg(source)

  # Render diagram source to an SVG string via a renderer that reads an input file
  # and writes an output file (System.cmd has no stdin). Mirrors chroma/2: a
  # non-zero exit or a missing binary yields nil, and the caller keeps the plain
  # block. `build_args` maps {in_path, out_path} to the renderer's argv.
  defp svg_via_files(cmd, build_args, source) do
    in_path = tmp_path()
    out_path = tmp_path()
    File.write!(in_path, source)

    try do
      case System.cmd(cmd, build_args.(in_path, out_path), stderr_to_stdout: true) do
        {_, 0} -> strip_to_svg(File.read!(out_path))
        _ -> nil
      end
    rescue
      _ -> nil
    after
      File.rm(in_path)
      File.rm(out_path)
    end
  end

  # Keep only the <svg>…</svg> element, dropping any XML prolog / DOCTYPE that
  # Graphviz emits and that is invalid mid-HTML. nil when there is no <svg>, so a
  # malformed render — or an empty ```svg block — falls back to the verbatim block.
  defp strip_to_svg(text) do
    case Regex.run(~r/<svg.*<\/svg>/s, text) do
      [svg] -> svg
      _ -> nil
    end
  end

  # chroma reads its input from a file, so the source round-trips through a temp
  # file. A non-zero exit — or a missing chroma — yields nil and the caller keeps
  # the plain block: highlighting is a nicety, never load-bearing.
  defp chroma(lexer, code) do
    path = tmp_path()
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

  defp tmp_path,
    do: Path.join(System.tmp_dir!(), "claudeview-#{:erlang.unique_integer([:positive])}")

  # cmark escapes only & < > in code text; unescape so a renderer sees the source
  # it expects (chroma re-escapes itself). The & substitution must come last.
  defp unescape(text) do
    text
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", "\"")
    |> String.replace("&#39;", "'")
    |> String.replace("&amp;", "&")
  end
end
