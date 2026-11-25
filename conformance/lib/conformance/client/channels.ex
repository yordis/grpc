defmodule Conformance.Client.Channels do
  @moduledoc """
  Keeps one channel for each address and set of connect options, so cases that connect the
  same way share it, as the reference client shares its HTTP transports.

  A channel for each case makes a TCP connection for each case, and the client, which
  closes it, keeps the socket in TIME_WAIT for twice the maximum segment lifetime. Several
  runs at once then hold most of the ephemeral ports, and connects fail.

  The channels stay open until the program exits. Connects run one at a time in this
  process, which owns the channels, so two cases never open the same channel twice.

  A kept channel outlives its TCP connections: when the server closes one, the channel
  dials again. A case waits for that (see `checkout/3`) instead of failing with
  `UNAVAILABLE` in between. A kept channel whose connection process exits is dropped, and
  the next case connects again, so no case gets a dead channel. A connect that raises or
  exits fails only the case that asked for it.

  This follows the reference client (connectconformance v1.0.7,
  `internal/app/referenceclient/transports.go`), which keeps one transport for each set of
  options, and whose transports never die:

    * Its HTTP/1.1 transport has no limit on connections (`MaxConnsPerHost` 0), so no case
      waits for another. Shared HTTP/1.1 channels open as many connections as cases run at
      once (see `Conformance.Client.Call`).
    * Its HTTP/1.1 cases that may end their call early (a cancel or a timeout) use a
      transport with `DisableKeepAlives`, which opens a connection for each request and
      closes it after. Such a case gets a channel of its own here, which it disconnects
      after the call (see `shared?/1`).
  """

  use GenServer

  alias Connectrpc.Conformance.V1.ClientCompatRequest

  # How long a case waits for a kept channel to connect again. Cases have 25 s in all.
  @ready_timeout 5_000

  @doc """
  Starts the channel store.

    * `:connect` opens a channel, `GRPC.Stub.connect/2` by default.
    * `:ready` waits for a kept channel to be connected, `GRPC.Client.Connection.await_ready/2`
      by default. It returns `:ok`, `{:error, :not_started}` for a channel that no longer
      runs, or another error.
    * `:connection` returns the process of a channel's connection, which the store monitors,
      or `nil` when there is none. By default the `GRPC.Client.Connection` of the channel.
    * `:name` registers the process.
  """
  def start_link(opts \\ []) do
    {connect, opts} = Keyword.pop(opts, :connect, &GRPC.Stub.connect/2)

    {ready, opts} =
      Keyword.pop(opts, :ready, &GRPC.Client.Connection.await_ready(&1, @ready_timeout))

    {connection, opts} = Keyword.pop(opts, :connection, &connection_pid/1)
    GenServer.start_link(__MODULE__, {connect, ready, connection}, opts)
  end

  @doc """
  Returns the channel for `addr` and `opts`, opening it when there is none, or when the one
  kept no longer runs. A kept channel is returned once it is connected, or after the wait
  is over, when the call reports how it fails.
  """
  def checkout(server \\ __MODULE__, addr, opts) do
    case GenServer.call(server, {:checkout, addr, opts}, :infinity) do
      {:kept, channel, ready} ->
        case ready.(channel) do
          {:error, :not_started} ->
            GenServer.call(server, {:replace, addr, opts, channel}, :infinity)

          _ ->
            {:ok, channel}
        end

      connected ->
        connected
    end
  end

  @doc """
  Whether the case may use a shared channel. An HTTP/1.1 connection carries one call at a
  time, and a call that ends early (cancelled, or past its deadline) closes it, so such a
  case gets a channel of its own, as it gets a connection of its own in the reference client.
  """
  def shared?(%ClientCompatRequest{http_version: :HTTP_VERSION_1} = req),
    do: is_nil(req.cancel) and is_nil(req.timeout_ms)

  def shared?(%ClientCompatRequest{}), do: true

  @impl true
  def init({connect, ready, connection}) do
    {:ok, %{connect: connect, ready: ready, connection: connection, channels: %{}, monitors: %{}}}
  end

  @impl true
  def handle_call({:checkout, addr, opts}, _from, state) do
    case Map.fetch(state.channels, {addr, opts}) do
      {:ok, {channel, pid, _mref}} ->
        if Process.alive?(pid) do
          {:reply, {:kept, channel, state.ready}, state}
        else
          reply_connect(evict(state, {addr, opts}), addr, opts)
        end

      :error ->
        reply_connect(state, addr, opts)
    end
  end

  # Another case may have replaced the channel already.
  def handle_call({:replace, addr, opts, dead}, _from, state) do
    case Map.fetch(state.channels, {addr, opts}) do
      {:ok, {^dead, _pid, _mref}} ->
        reply_connect(evict(state, {addr, opts}), addr, opts)

      {:ok, {channel, _pid, _mref}} ->
        {:reply, {:ok, channel}, state}

      :error ->
        reply_connect(state, addr, opts)
    end
  end

  @impl true
  def handle_info({:DOWN, mref, :process, _pid, _reason}, state) do
    case Map.pop(state.monitors, mref) do
      {nil, _} ->
        {:noreply, state}

      {key, monitors} ->
        {:noreply, %{state | channels: Map.delete(state.channels, key), monitors: monitors}}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp evict(state, key) do
    case Map.pop(state.channels, key) do
      {nil, _} ->
        state

      {{_channel, _pid, mref}, channels} ->
        Process.demonitor(mref, [:flush])
        %{state | channels: channels, monitors: Map.delete(state.monitors, mref)}
    end
  end

  defp reply_connect(state, addr, opts) do
    case connect(state, addr, opts) do
      {:ok, channel, state} -> {:reply, {:ok, channel}, state}
      error -> {:reply, error, state}
    end
  end

  # A connect that raises or exits fails the case that asked for it, not the store. A
  # channel with no connection process is handed out but not kept.
  defp connect(state, addr, opts) do
    case state.connect.(addr, opts) do
      {:ok, channel} -> {:ok, channel, keep(state, {addr, opts}, channel)}
      error -> error
    end
  rescue
    error -> {:error, error}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp keep(state, key, channel) do
    case state.connection.(channel) do
      pid when is_pid(pid) ->
        mref = Process.monitor(pid)

        %{
          state
          | channels: Map.put(state.channels, key, {channel, pid, mref}),
            monitors: Map.put(state.monitors, mref, key)
        }

      nil ->
        state
    end
  end

  defp connection_pid(%GRPC.Channel{ref: ref}) do
    case Registry.lookup(GRPC.Client.Registry, {GRPC.Client.Connection, ref}) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end
end
