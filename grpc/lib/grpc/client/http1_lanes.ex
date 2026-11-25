defmodule GRPC.Client.HTTP1Lanes do
  @moduledoc false

  # HTTP/1.1 carries one call at a time on a connection. A call that finds the channel's
  # connection busy runs on a connection of its own, a lane, for that one call. This module
  # counts the lanes of a channel and holds the calls over the limit until a lane ends.
  #
  # The connection process of the channel owns a `t:t/0` and answers the calls below. A
  # caller reserves a slot, starts its lane, attaches the lane to the slot, and the slot
  # frees when the lane process exits.

  @default_max_connections 8
  @reserve_timeout 5_000
  # A reservation the caller never attached to a lane frees itself.
  @reservation_ttl 30_000

  defstruct max: @default_max_connections - 1, monitors: %{}, waiting: :queue.new()

  @type t :: %__MODULE__{}

  def default_max_connections, do: @default_max_connections

  @doc "Checks the `:http1_max_connections` option."
  def validate(opts) do
    case Keyword.fetch(opts, :http1_max_connections) do
      :error ->
        :ok

      {:ok, value} when is_integer(value) and value >= 1 ->
        :ok

      {:ok, value} ->
        {:error, ":http1_max_connections must be a positive integer, got: #{inspect(value)}"}
    end
  end

  ## Client side

  @doc "Reserves a lane on the channel's connection process. Waits when all are taken."
  def acquire(connection_process) do
    GenServer.call(connection_process, :reserve_lane, @reserve_timeout)
  catch
    :exit, {:timeout, _} ->
      {:error,
       GRPC.RPCError.exception(
         GRPC.Status.unavailable(),
         "all the HTTP/1.1 connections of the channel are busy"
       )}
  end

  @doc "Ties the lane process to the reserved slot."
  def attach(connection_process, token, lane),
    do: GenServer.call(connection_process, {:attach_lane, token, lane})

  @doc "Gives a slot back when no lane was started."
  def release(connection_process, token),
    do: GenServer.cast(connection_process, {:release_lane, token})

  ## Connection process side

  def new(max_connections) when is_integer(max_connections) and max_connections >= 1,
    do: %__MODULE__{max: max_connections - 1}

  def member?(%__MODULE__{monitors: monitors}, ref), do: Map.has_key?(monitors, ref)

  @doc "Handles `:reserve_lane`: replies now, or holds the caller."
  def reserve(%__MODULE__{} = lanes, {caller, _tag} = from) do
    if map_size(lanes.monitors) < lanes.max do
      {token, lanes} = grant(lanes, caller)
      {:reply, {:ok, token}, lanes}
    else
      {:noreply, %{lanes | waiting: :queue.in(from, lanes.waiting)}}
    end
  end

  @doc "Handles `{:attach_lane, token, lane}`."
  def attach_lane(%__MODULE__{} = lanes, token, lane) do
    case Map.pop(lanes.monitors, token) do
      {{:reserved, timer}, monitors} ->
        Process.cancel_timer(timer)
        Process.demonitor(token, [:flush])
        ref = Process.monitor(lane)
        {:ok, %{lanes | monitors: Map.put(monitors, ref, :lane)}}

      {_, _monitors} ->
        {:error, lanes}
    end
  end

  @doc "Frees a slot, by its reservation or lane monitor, and serves a waiting caller."
  def free(%__MODULE__{} = lanes, ref) do
    case Map.pop(lanes.monitors, ref) do
      {nil, _monitors} ->
        lanes

      {entry, monitors} ->
        Process.demonitor(ref, [:flush])
        with {:reserved, timer} <- entry, do: Process.cancel_timer(timer)
        serve_waiting(%{lanes | monitors: monitors})
    end
  end

  defp serve_waiting(lanes) do
    with true <- map_size(lanes.monitors) < lanes.max,
         {{:value, {caller, _tag} = from}, waiting} <- :queue.out(lanes.waiting) do
      {token, lanes} = grant(%{lanes | waiting: waiting}, caller)
      GenServer.reply(from, {:ok, token})
      serve_waiting(lanes)
    else
      _ -> lanes
    end
  end

  # The reservation is watched through the caller: if it dies, the slot frees.
  defp grant(lanes, caller) do
    token = Process.monitor(caller)
    timer = Process.send_after(self(), {:lane_expired, token}, @reservation_ttl)
    {token, %{lanes | monitors: Map.put(lanes.monitors, token, {:reserved, timer})}}
  end
end
