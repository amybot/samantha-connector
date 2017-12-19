defmodule Connector.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  def start(_type, _args) do
    IO.puts "Starting samantha shard connector..."
    # List all child processes to be supervised
    children = [
      # Redis and clustering
      {Lace.Redis, %{redis_ip: System.get_env("REDIS_IP"), redis_port: 6379, pool_size: 10, redis_pass: System.get_env("REDIS_PASS")}},
      {Connector.Sharder, :ok},
      {Amelia, []},
      #{Lace, %{name: "node_name", group: "group_name", cookie: "node_cookie"}},

      # Plug
      Plug.Adapters.Cowboy.child_spec(:http, Connector.Router, [], [
          dispatch: dispatch(),
          port: 8080,
        ]),
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Connector.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp dispatch do
    [
      {:_, [
        {:_, Plug.Adapters.Cowboy.Handler, {Connector.Router, []}}
      ]},
    ]
  end
end
