defmodule Claudeview.Router do
  @moduledoc "HTTP surface: the viewer, its assets, the SSE stream and the push endpoint."

  use Plug.Router

  plug :match
  plug :dispatch

  get "/" do
    serve(conn, "index.html")
  end

  get "/assets/:name" do
    serve(conn, name)
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
    |> send_resp(200, Jason.encode!(%{tabs: tabs, focus: focus}))
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
    dir = System.get_env("WATCH_DIR", "content")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, tab <> ".md"), body)
    send_resp(conn, 200, "ok\n")
  end

  match _ do
    send_resp(conn, 404, "not found\n")
  end

  # Static assets

  defp serve(conn, name) do
    path = Path.join(web_dir(), Path.basename(name))

    if File.exists?(path) do
      conn
      |> put_resp_content_type(content_type(path))
      |> send_file(200, path)
    else
      send_resp(conn, 404, "not found\n")
    end
  end

  defp web_dir, do: System.get_env("WEB_DIR", "priv/web")

  defp content_type(path) do
    cond do
      String.ends_with?(path, ".html") -> "text/html"
      String.ends_with?(path, ".js") -> "text/javascript"
      String.ends_with?(path, ".css") -> "text/css"
      true -> "application/octet-stream"
    end
  end

  defp safe_name(name) do
    name |> Path.basename() |> String.replace(~r/[^A-Za-z0-9_.-]/, "_")
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
