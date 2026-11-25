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
  `UNAVAILABLE` in between.
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
    * `:name` registers the process.
  """
  def start_link(opts \\ []) do
    {connect, opts} = Keyword.pop(opts, :connect, &GRPC.Stub.connect/2)

    {ready, opts} =
      Keyword.pop(opts, :ready, &GRPC.Client.Connection.await_ready(&1, @ready_timeout))

    GenServer.start_link(__MODULE__, {connect, ready}, opts)
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
  def init({connect, ready}), do: {:ok, %{connect: connect, ready: ready, channels: %{}}}

  @impl true
  def handle_call({:checkout, addr, opts}, _from, state) do
    case Map.fetch(state.channels, {addr, opts}) do
      {:ok, channel} ->
        {:reply, {:kept, channel, state.ready}, state}

      :error ->
        reply_connect(state, addr, opts)
    end
  end

  # Another case may have replaced the channel already.
  def handle_call({:replace, addr, opts, dead}, _from, state) do
    case Map.fetch(state.channels, {addr, opts}) do
      {:ok, ^dead} ->
        reply_connect(%{state | channels: Map.delete(state.channels, {addr, opts})}, addr, opts)

      {:ok, channel} ->
        {:reply, {:ok, channel}, state}

      :error ->
        reply_connect(state, addr, opts)
    end
  end

  defp reply_connect(state, addr, opts) do
    case connect(state, addr, opts) do
      {:ok, channel, state} -> {:reply, {:ok, channel}, state}
      error -> {:reply, error, state}
    end
  end

  # A connect that raises or exits fails the case that asked for it, not the store.
  defp connect(state, addr, opts) do
    case state.connect.(addr, opts) do
      {:ok, channel} -> {:ok, channel, put_in(state.channels[{addr, opts}], channel)}
      error -> error
    end
  rescue
    error -> {:error, error}
  catch
    kind, reason -> {:error, {kind, reason}}
  end
end
