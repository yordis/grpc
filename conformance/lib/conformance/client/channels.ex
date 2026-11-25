defmodule Conformance.Client.Channels do
  @moduledoc """
  Keeps one channel for each address and set of connect options, so cases that connect the
  same way share it, as the reference client shares its HTTP transports.

  A channel for each case makes a TCP connection for each case, and the client, which
  closes it, keeps the socket in TIME_WAIT for twice the maximum segment lifetime. Several
  runs at once then hold most of the ephemeral ports, and connects fail.

  The channels stay open until the program exits. Connects run one at a time in this
  process, which owns the channels, so two cases never open the same channel twice.
  """

  use GenServer

  alias Connectrpc.Conformance.V1.ClientCompatRequest

  @doc """
  Starts the channel store. `:connect` is the function that opens a channel,
  `GRPC.Stub.connect/2` by default, and `:name` registers the process.
  """
  def start_link(opts \\ []) do
    {connect, opts} = Keyword.pop(opts, :connect, &GRPC.Stub.connect/2)
    GenServer.start_link(__MODULE__, connect, opts)
  end

  @doc "Returns the channel for `addr` and `opts`, opening it when there is none."
  def checkout(server \\ __MODULE__, addr, opts),
    do: GenServer.call(server, {:checkout, addr, opts}, :infinity)

  @doc """
  Whether the case may use a shared channel. An HTTP/1.1 connection carries one call at a
  time, and a call that ends early (cancelled, or past its deadline) closes it, so such a
  case gets a channel of its own, as it gets a connection of its own in the reference client.
  """
  def shared?(%ClientCompatRequest{http_version: :HTTP_VERSION_1} = req),
    do: is_nil(req.cancel) and is_nil(req.timeout_ms)

  def shared?(%ClientCompatRequest{}), do: true

  @impl true
  def init(connect), do: {:ok, %{connect: connect, channels: %{}}}

  @impl true
  def handle_call({:checkout, addr, opts}, _from, state) do
    key = {addr, opts}

    case Map.fetch(state.channels, key) do
      {:ok, channel} ->
        {:reply, {:ok, channel}, state}

      :error ->
        case state.connect.(addr, opts) do
          {:ok, channel} ->
            {:reply, {:ok, channel}, put_in(state.channels[key], channel)}

          error ->
            {:reply, error, state}
        end
    end
  end
end
