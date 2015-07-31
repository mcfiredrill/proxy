require Logger

defmodule Proxy do
  use Plug.Builder
  import Plug.Conn

  # @target "http://google.com"
  @target "http://datafruits.streampusher.com:49236"

  plug Plug.Logger
  plug :dispatch

  def start(_argv) do
    port = 4001
    IO.puts "Running Proxy with Cowboy on http://localhost:#{port}"
    Plug.Adapters.Cowboy.http __MODULE__, [], port: port
    :timer.sleep(:infinity)
  end

  def dispatch(conn, _opts) do
    # Start a request to the client saying we will stream the body.
    # We are simply passing all req_headers forward.
    {:ok, client} = :hackney.request(:get, uri(conn), conn.req_headers, :stream, [])

    conn
    |> write_proxy(client)
    |> read_proxy(client)
  end

  # Reads the connection body and write it to the
  # client recursively.
  defp write_proxy(conn, client) do
    # Check Plug.Conn.read_body/2 docs for maximum body value,
    # the size of each chunk, and supported timeout values.
    case read_body(conn, [{:length, 100}]) do
      {:ok, body, conn} ->
        Logger.info "reading body"
        :hackney.send_body(client, body)
        Logger.info "sent body from ok"
        conn
      {:more, body, conn} ->
        Logger.info "more body"
        :hackney.send_body(client, body)
        Logger.info "sent body from more"
        write_proxy(conn, client)
    end
  end

  # Reads the client response and sends it back.
  defp read_proxy(conn, client) do
    Logger.info "in read_proxy"
    {:ok, status, headers, client} = :hackney.start_response(client)
    Logger.info "started response"

    # Delete the transfer encoding header. Ideally, we would read
    # if it is chunked or not and act accordingly to support streaming.
    #
    # We may also need to delete other headers in a proxy.
    # headers = List.keydelete(headers, "Transfer-Encoding", 1)
    Logger.info(status)
    #Logger.info(headers)

    conn = send_chunked(conn, status)
    stream_loop(conn,client)
    conn
  end

  def stream_loop(conn, client) do
    stream_hackney_response(conn, client)
    |> Stream.each(&chunk(conn, &1))
    |> Stream.run
  end

  def stream_hackney_response(conn, client) do
    Stream.resource(
        fn -> client end,
        &continue_response/1,
        fn ref ->
          Logger.info "closing client"
          :hackney.close(client)
        end
    )
  end

  def continue_response(client) do
    Logger.info "in continue_response"
    case :hackney.stream_body(client) do
        {:ok, data} -> {[data], client}
        :done ->
          Logger.info "No more data"
          client
        {:error, reason} ->
          raise reason
    end
  end

  defp uri(conn) do
    base = @target <> "/" <> Enum.join(conn.path_info, "/")
    case conn.query_string do
      "" -> base
      qs -> base <> "?" <> qs
    end
  end

end
