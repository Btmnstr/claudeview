defmodule Claudeview.Router do
  @moduledoc """
  The HTTP surface, a `Plug.Router`: the viewer and its static assets, the JSON
  content snapshot, the SSE stream and the push endpoint.

  Most routes (`/`, `/assets`, `/media`, `/download`, `/content`, `/push`,
  `/clear-old`) build one response and return. `/events` is the exception: it
  opens a chunked response and then
  *stays* in a receive loop (`sse_loop/1` ↔ `send_chunk/2`), forwarding a chunk
  whenever the Store signals `:changed` — and a keep-alive comment otherwise — for
  the life of the connection. `/content` reports the newest-modified tab as the
  focus; the viewer honours or overrides it per its pin state.
  """

  use Plug.Router

  plug(:match)
  plug(:dispatch)

  get "/" do
    serve(conn, "index.html")
  end

  get "/assets/:name" do
    serve(conn, name)
  end

  # Images an author dropped beside their .md, referenced as ![alt](name.png).
  # Served from the watch dir; safe_name/1 collapses to a basename, so a request
  # can never escape it (flat layout — images live directly in the watch dir).
  get "/media/:name" do
    send_static(conn, Path.join(Claudeview.Config.watch_dir(), safe_name(name)))
  end

  # Hand back a document's raw Markdown as a download. The tab name resolves to a
  # real `.md` on disk (see resolve_download/1); the browser's same-origin
  # `download` attribute names the saved file, and the headers make a direct hit
  # save rather than render too.
  get "/download/:name" do
    case resolve_download(name) do
      nil ->
        not_found(conn)

      path ->
        conn
        |> put_resp_content_type("text/markdown")
        |> put_resp_header(
          "content-disposition",
          ~s(attachment; filename="#{safe_name(name)}.md")
        )
        |> send_file(200, path)
    end
  end

  get "/content" do
    tabs =
      Claudeview.Store.snapshot()
      |> Enum.map(fn {name, t} -> %{name: name, html: t.html, mtime: t.mtime} end)
      |> Enum.sort_by(& &1.mtime)

    focus =
      case List.last(tabs) do
        nil -> nil
        tab -> tab.name
      end

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(%{tabs: tabs, focus: focus, watching: watching_paths()}))
  end

  get "/events" do
    Claudeview.Store.subscribe()

    conn
    |> put_resp_header("content-type", "text/event-stream")
    |> put_resp_header("cache-control", "no-cache")
    |> send_chunked(200)
    # Sync immediately: every (re)connect makes the viewer refetch fresh content.
    |> send_chunk("data: changed\n\n")
  end

  post "/push" do
    conn = fetch_query_params(conn)
    tab = safe_name(conn.query_params["tab"] || "push")
    {:ok, body, conn} = read_body(conn)
    dir = push_dir()
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, tab <> ".md"), body)
    send_resp(conn, 200, "ok\n")
  end

  # "Clear old" garbage collection. The viewer, which alone knows the grouping and
  # which documents are starred, sends the exact list of stale tabs to delete plus
  # its keep-count; the server just removes their files. It also sweeps each
  # collapsed (plan-mode) directory down to the newest `keep` files — those pile up
  # invisibly, so the UI can't name them. Body: {"delete": [names], "keep": n}.
  post "/clear-old" do
    {:ok, body, conn} = read_body(conn)
    params = decode_body(body)
    names = Map.get(params, "delete", [])
    keep = Map.get(params, "keep", Claudeview.Config.keep_per_group())
    send_resp(conn, 200, "removed #{clear_old(names, keep)}\n")
  end

  match _ do
    not_found(conn)
  end

  # Static assets

  defp serve(conn, name) do
    send_static(conn, Path.join(Claudeview.Config.web_dir(), Path.basename(name)))
  end

  # Serve a file under its content type, or 404 when it is absent. The two static
  # routes — assets from web_dir, author images from the watch dir — differ only
  # in how they build `path`, so the send/404 shape lives here once.
  defp send_static(conn, path) do
    if File.exists?(path) do
      conn
      |> put_resp_content_type(content_type(path))
      |> send_file(200, path)
    else
      not_found(conn)
    end
  end

  defp not_found(conn), do: send_resp(conn, 404, "not found\n")

  # The parsed `WATCH_DIR` specs — `{dir, tab | nil}` per entry. Several routes
  # resolve names against them, so the read-and-parse lives here once.
  defp specs, do: Claudeview.Watcher.parse_specs(Claudeview.Config.watch_dir())

  # Where an HTTP push lands: the first watched directory. WATCH_DIR may list
  # several specs (e.g. "/content:/plans=plan"), but a push only ever writes the
  # primary one — the same directory the file-delivery hook writes to.
  defp push_dir do
    specs()
    |> List.first()
    |> elem(0)
  end

  # Resolve a tab name to the `.md` file behind it, or nil when none exists. The
  # two watch modes locate it differently (mirroring `Claudeview.Watcher`): a
  # per-file dir holds `<name>.md` directly, while a collapsed `DIR=TAB` dir shows
  # its newest file under the fixed tab name, so we hand back that same newest file.
  @spec resolve_download(String.t()) :: Path.t() | nil
  defp resolve_download(name) do
    specs()
    |> Enum.find_value(fn
      {dir, nil} ->
        path = Path.join(dir, safe_name(name) <> ".md")
        if File.exists?(path), do: path

      {dir, ^name} ->
        newest_md(dir)

      {_dir, _tab} ->
        nil
    end)
  end

  # The newest `*.md` in a collapsed directory — the one its single tab shows.
  # Reads mtime as `:posix` (matching Watcher/Gc) and tolerates a file that
  # vanishes mid-scan rather than raising, the way `File.stat!` would.
  @spec newest_md(String.t()) :: Path.t() | nil
  defp newest_md(dir) do
    dir
    |> Path.join("*.md")
    |> Path.wildcard()
    |> Enum.max_by(&mtime/1, fn -> nil end)
  end

  defp mtime(path) do
    case File.stat(path, time: :posix) do
      {:ok, %File.Stat{mtime: mtime}} -> mtime
      {:error, _} -> 0
    end
  end

  # Tolerant JSON body decode: a malformed or empty body clears nothing rather
  # than crashing the request.
  defp decode_body(body) do
    case Jason.decode(body) do
      {:ok, %{} = map} -> map
      _ -> %{}
    end
  end

  # Delete the named stale tabs from the per-file dirs, then sweep each collapsed
  # directory to its newest `keep` files — together leaving the watch tree
  # mirroring what the UI still shows. Returns the number of files removed. The
  # watcher's next poll would drop the vanished tabs on its own; the explicit
  # `Store.drop/1` makes them disappear from the viewer at once. `Claudeview.Gc`
  # does the disk work; name sanitization stays here where `safe_name/1` lives.
  defp clear_old(names, keep) do
    specs = specs()
    per_file = for {dir, nil} <- specs, do: dir
    collapsed = for {dir, tab} <- specs, tab != nil, do: dir

    removed = Claudeview.Gc.remove(Enum.map(names, &safe_name/1), per_file)
    Enum.each(removed, &Claudeview.Store.drop/1)
    length(removed) + Claudeview.Gc.sweep(collapsed, keep)
  end

  # Host-facing description of what the server is watching, one entry per
  # `WATCH_DIR` spec. A plain directory shows its human label (the container only
  # knows /content, so `CLAUDEVIEW_LABEL` supplies a meaningful path); a collapsed
  # `DIR=TAB` spec shows "<tab> tab" instead of its opaque container path.
  defp watching_paths do
    specs()
    |> Enum.map(&label_spec/1)
  end

  defp label_spec({dir, nil}), do: Claudeview.Config.label() || dir
  defp label_spec({_dir, tab}), do: "#{tab} tab"

  @content_types %{
    ".html" => "text/html",
    ".js" => "text/javascript",
    ".css" => "text/css",
    ".woff2" => "font/woff2",
    ".png" => "image/png",
    ".jpg" => "image/jpeg",
    ".jpeg" => "image/jpeg",
    ".gif" => "image/gif",
    ".webp" => "image/webp",
    ".svg" => "image/svg+xml"
  }

  @spec content_type(Path.t()) :: String.t()
  defp content_type(path) do
    ext = path |> Path.extname() |> String.downcase()
    Map.get(@content_types, ext, "application/octet-stream")
  end

  # `~` is kept: it is the reserved session/doc delimiter in tab names, and the
  # local and HTTP push paths must agree on it or a remote push would be mangled.
  @spec safe_name(String.t()) :: String.t()
  defp safe_name(name) do
    name |> Path.basename() |> String.replace(~r/[^A-Za-z0-9_.~-]/, "_")
  end

  # Server-Sent Events: block until the store signals a change, then ping the
  # client. A comment line every 20s keeps proxies from closing an idle stream.
  @spec sse_loop(Plug.Conn.t()) :: Plug.Conn.t()
  defp sse_loop(conn) do
    receive do
      :changed -> send_chunk(conn, "data: changed\n\n")
    after
      20_000 -> send_chunk(conn, ": ping\n\n")
    end
  end

  # Write one chunk, then re-enter `sse_loop/1` to await the next: the two
  # mutually recurse to stream for the connection's life. A write error means the
  # client hung up, which ends the recursion and lets the request finish.
  @spec send_chunk(Plug.Conn.t(), iodata()) :: Plug.Conn.t()
  defp send_chunk(conn, data) do
    case chunk(conn, data) do
      {:ok, conn} -> sse_loop(conn)
      {:error, _} -> conn
    end
  end
end
