defmodule Claudeview.Router do
  @moduledoc "HTTP surface: the viewer, its assets, the SSE stream and the push endpoint."

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
    dir = System.get_env("WATCH_DIR", "content")
    send_static(conn, Path.join(dir, safe_name(name)))
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

  match _ do
    not_found(conn)
  end

  # Static assets

  defp serve(conn, name) do
    send_static(conn, Path.join(web_dir(), Path.basename(name)))
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

  defp web_dir, do: System.get_env("WEB_DIR", "priv/web")

  # Where an HTTP push lands: the first watched directory. WATCH_DIR may list
  # several specs (e.g. "/content:/plans=plan"), but a push only ever writes the
  # primary one — the same directory the file-delivery hook writes to.
  defp push_dir do
    System.get_env("WATCH_DIR", "content")
    |> Claudeview.Watcher.parse_specs()
    |> List.first()
    |> elem(0)
  end

  # Host-facing description of what the server is watching, one entry per
  # `WATCH_DIR` spec. A plain directory shows its human label (the container only
  # knows /content, so `CLAUDEVIEW_LABEL` supplies a meaningful path); a collapsed
  # `DIR=TAB` spec shows "<tab> tab" instead of its opaque container path.
  defp watching_paths do
    System.get_env("WATCH_DIR", "content")
    |> Claudeview.Watcher.parse_specs()
    |> Enum.map(&label_spec/1)
  end

  defp label_spec({dir, nil}), do: System.get_env("CLAUDEVIEW_LABEL") || dir
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

  defp content_type(path) do
    ext = path |> Path.extname() |> String.downcase()
    Map.get(@content_types, ext, "application/octet-stream")
  end

  # `~` is kept: it is the reserved session/doc delimiter in tab names, and the
  # local and HTTP push paths must agree on it or a remote push would be mangled.
  defp safe_name(name) do
    name |> Path.basename() |> String.replace(~r/[^A-Za-z0-9_.~-]/, "_")
  end

  # Server-Sent Events: block until the store signals a change, then ping the
  # client. A comment line every 20s keeps proxies from closing an idle stream.
  defp sse_loop(conn) do
    receive do
      :changed -> send_chunk(conn, "data: changed\n\n")
    after
      20_000 -> send_chunk(conn, ": ping\n\n")
    end
  end

  defp send_chunk(conn, data) do
    case chunk(conn, data) do
      {:ok, conn} -> sse_loop(conn)
      {:error, _} -> conn
    end
  end
end
