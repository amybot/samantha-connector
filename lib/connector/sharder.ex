defmodule Connector.Sharder do
  @moduledoc """
  Handles the state per-bot, including assigned / available shards, etc.
  """

  use GenServer
  alias Lace.Redis
  require Logger

  # Only allow connecting a shard once every 6.5 seconds, just to be sure we dodge the OP2 ratelimit
  @interval 6500
  # How many ms a shard has before its heartbeats run out and it can be replaced
  @shard_timeout 10000

  def start_link(_) do
    GenServer.start_link __MODULE__, :ok, name: :sharder
  end

  def init(opts) do
    {:ok, opts}
  end

  def handle_info({:heartbeat, packet}, state) do
    # Our input looks like
    # %{
    #   "bot_name" => "my-cool-bot",
    #   "shard_id" => 42,
    # }

    # Write the heartbeat time to the registry
    reg = reg_name packet["bot_name"]
    Redis.q ["HSET", reg, packet["shard_id"], :os.system_time(:millisecond)]
    {:noreply, state}
  end

  def handle_call({:connect, packet}, _from, state) do
    GenServer.call Amelia, {:lock, :shard_connect}
    # Our input looks like
    # %{
    #   "bot_name"    => "my-cool-bot",
    #   "shard_count" => 50000,
    # }
    bot_name = packet["bot_name"]
    Logger.info "Attempting to connect #{inspect bot_name}"

    # Check in redis to see when the last connect was
    reg = reg_name bot_name
    conn = "#{reg}-last-connect"
    {:ok, res} = Redis.q ["GET", conn]
    last_connect = case res do
                     # If no connection exists, then we can connect whenever
                     :undefined -> -1
                     # Otherwise, convert it to an integer
                     _ -> res |> String.to_integer
                   end

    now = :os.system_time(:millisecond)
    # If the last connection was more than @interval ms ago, we can connect
    if last_connect + @interval < now do
      # Lock to prevent other PIDs from taking out shards
      shard_count = packet["shard_count"]
      # Find an available shard id
      {:ok, res} = Redis.q ["HGETALL", reg]
      shard_map = res
      |> Enum.chunk(2)
      |> Enum.map(fn [a, b] -> {a, b |> String.to_integer} end)
      |> Enum.filter(fn {a, b} -> a != nil and b != nil end)
      |> Enum.to_list
      if length(shard_map) < shard_count do
        # Pre-populate with shard IDs
        for shard <- 0..(shard_count - 1) do
          Logger.info "Pre-populating shard IDs for #{inspect bot_name}"
          Redis.q ["HSET", reg, shard |> Integer.to_string, "-1"]
        end
      end
      # Check the last shard connect time for all shards
      available_shards = shard_map
      |> Enum.filter(fn {_, heartbeat_time} -> heartbeat_time + @shard_timeout < now end)
      |> Enum.to_list
      unless length(available_shards) == 0 do
        {shard, _} = available_shards |> List.first
        Logger.info "Shard #{inspect shard} available, connecting!"
        # Write this to the registry as the first heartbeat
        Redis.q ["HSET", reg, shard, :os.system_time(:millisecond)]
        GenServer.call Amelia, {:unlock, :shard_connect}
        {:reply, %{
          "bot_name"    => bot_name,
          "can_connect" => true,
          "shard_id"    => shard
        }, state}
      else
        Logger.info "No shards available, not connecting!"
        GenServer.call Amelia, {:unlock, :shard_connect}
        {:reply, %{
          "bot_name"    => bot_name,
          "can_connect" => false,
        }, state}
      end
    else
      GenServer.call Amelia, {:unlock, :shard_connect}
      Logger.info "Connecting too fast, not connecting!"
      {:reply, %{
          "bot_name"    => bot_name,
          "can_connect" => false,
        }, state}
    end
  end

  defp reg_name(name) do
    "samantha-reg-#{name}"
  end
end