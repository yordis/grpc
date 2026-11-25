defmodule GRPC.Client.HTTP1Lanes do
  @moduledoc false

  # HTTP/1.1 carries one call at a time on a connection. A call that finds the channel's
  # connection busy runs on a connection of its own, a lane, for that one call. This module
  # counts the lanes of a channel and holds the calls over the limit until a lane ends.
  #
  # The connection process of the channel owns a `t:t/0` and answers the messages below. A
  # caller reserves a slot, starts its lane, attaches the lane to the slot, and the slot
  # frees when the lane process exits. A caller that waits for a slot gives up when its
  # deadline passes, its cancel handle is cancelled, or the wait limit is over, and the
  # connection process drops it from the queue.

  @default_max_connections 8
  # The longest a call waits for a slot, when its deadline does not end the wait first.
  @reserve_timeout 5_000
  # How often a waiting call looks at its cancel handle.
  @poll 25
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

      {:ok, value} when is_integer(value) and value >= 2 ->
        :ok

      {:ok, value} ->
        {:error, ":http1_max_connections must be an integer of 2 or more, got: #{inspect(value)}"}
    end
  end

  ## Client side

  @doc """
  Reserves a lane on the channel's connection process. Waits when all are taken, until a
  lane frees, the `:deadline` of the call (milliseconds on the monotonic clock) passes, the
  `:cancel` handle of the call is cancelled, or 5 seconds go by.
  """
  def acquire(connection_process, opts \\ []) do
    tag = make_ref()
    monitor = Process.monitor(connection_process)
    GenServer.cast(connection_process, {:reserve_lane, self(), tag})

    wait(connection_process, tag, monitor, now() + @reserve_timeout, opts)
  end

  defp wait(connection_process, tag, monitor, limit, opts) do
    case give_up_reason(opts[:cancel], opts[:deadline], limit) do
      nil ->
        until = if is_integer(opts[:deadline]), do: min(opts[:deadline], limit), else: limit

        receive do
          {^tag, {:ok, _token} = reply} ->
            Process.demonitor(monitor, [:flush])
            reply

          {:DOWN, ^monitor, :process, _pid, reason} ->
            exit(
              {reason, {GenServer, :call, [connection_process, :reserve_lane, @reserve_timeout]}}
            )
        after
          min(@poll, max(until - now(), 0)) ->
            wait(connection_process, tag, monitor, limit, opts)
        end

      reason ->
        give_up(connection_process, tag, monitor)
        {:error, error(reason)}
    end
  end

  defp give_up_reason(cancel, deadline, limit) do
    cond do
      match?(%GRPC.Client.CancelHandle{}, cancel) and GRPC.Client.CancelHandle.canceled?(cancel) ->
        :cancelled

      is_integer(deadline) and now() >= deadline ->
        :deadline

      now() >= limit ->
        :busy

      true ->
        nil
    end
  end

  defp give_up(connection_process, tag, monitor) do
    Process.demonitor(monitor, [:flush])

    try do
      GenServer.call(connection_process, {:give_up, tag}, @reserve_timeout)
    catch
      :exit, _reason -> :ok
    end

    # The slot may have been granted while the call gave up. The connection process
    # freed it, and the reply is dropped.
    receive do
      {^tag, _reply} -> :ok
    after
      0 -> :ok
    end
  end

  defp error(:cancelled),
    do: GRPC.RPCError.exception(GRPC.Status.cancelled(), "The operation was cancelled")

  defp error(:deadline),
    do: GRPC.RPCError.exception(GRPC.Status.deadline_exceeded(), "deadline exceeded")

  defp error(:busy),
    do:
      GRPC.RPCError.exception(
        GRPC.Status.unavailable(),
        "all the HTTP/1.1 connections of the channel are busy"
      )

  defp now, do: System.monotonic_time(:millisecond)

  @doc "Ties the lane process to the reserved slot."
  def attach(connection_process, token, lane),
    do: GenServer.call(connection_process, {:attach_lane, token, lane})

  @doc "Gives a slot back when no lane was started."
  def release(connection_process, token),
    do: GenServer.cast(connection_process, {:release_lane, token})

  ## Connection process side

  def new(max_connections) when is_integer(max_connections) and max_connections >= 2,
    do: %__MODULE__{max: max_connections - 1}

  def member?(%__MODULE__{monitors: monitors}, ref), do: Map.has_key?(monitors, ref)

  @doc "Handles `{:reserve_lane, caller, tag}`: answers the caller now, or holds it."
  def reserve(%__MODULE__{} = lanes, caller, tag) do
    if map_size(lanes.monitors) < lanes.max do
      grant(lanes, caller, tag)
    else
      %{lanes | waiting: :queue.in({caller, tag}, lanes.waiting)}
    end
  end

  @doc "Handles `{:give_up, tag}`: drops the call from the queue, or frees the slot it was given."
  def give_up(%__MODULE__{} = lanes, tag) do
    waiting = :queue.filter(fn {_caller, waiting_tag} -> waiting_tag != tag end, lanes.waiting)
    lanes = %{lanes | waiting: waiting}

    case Enum.find(lanes.monitors, &match?({_ref, {:reserved, _timer, ^tag}}, &1)) do
      {ref, _entry} -> free(lanes, ref)
      nil -> lanes
    end
  end

  @doc "Handles `{:attach_lane, token, lane}`."
  def attach_lane(%__MODULE__{} = lanes, token, lane) do
    case Map.pop(lanes.monitors, token) do
      {{:reserved, timer, _tag}, monitors} ->
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
        with {:reserved, timer, _tag} <- entry, do: Process.cancel_timer(timer)
        serve_waiting(%{lanes | monitors: monitors})
    end
  end

  defp serve_waiting(lanes) do
    with true <- map_size(lanes.monitors) < lanes.max,
         {{:value, {caller, tag}}, waiting} <- :queue.out(lanes.waiting) do
      %{lanes | waiting: waiting} |> grant(caller, tag) |> serve_waiting()
    else
      _ -> lanes
    end
  end

  # The reservation is watched through the caller: if it dies, the slot frees.
  defp grant(lanes, caller, tag) do
    token = Process.monitor(caller)
    timer = Process.send_after(self(), {:lane_expired, token}, @reservation_ttl)
    send(caller, {tag, {:ok, token}})
    %{lanes | monitors: Map.put(lanes.monitors, token, {:reserved, timer, tag})}
  end
end
