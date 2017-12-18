defmodule Connector.Router do
  use Plug.Router

  plug :match
  plug Plug.Parsers, parsers: [:json],
                   pass:  ["application/json"],
                   json_decoder: Poison
  plug :dispatch

  get "/", do: send_resp(conn, 200, "yes")

  post "/shard" do
    res = GenServer.call :sharder, {:connect, conn.body_params}
    send_resp conn, 200, res |> Poison.encode!
  end

  post "/heartbeat" do
    send :sharder, {:heartbeat, conn.body_params}
    send_resp conn, 200, ":ok"
  end

  match _, do: send_resp(conn, 404, "no")
end