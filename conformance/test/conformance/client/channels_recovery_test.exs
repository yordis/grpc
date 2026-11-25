defmodule Conformance.Client.ChannelsRecoveryTest do
  # The endpoint has one name, so the tests take turns.
  use ExUnit.Case, async: false

  alias Connectrpc.Conformance.V1.{ConformanceService.Stub, UnaryRequest}
  alias Conformance.Client.Channels

  @adapters [GRPC.Client.Adapters.Mint, GRPC.Client.Adapters.Gun]
  @protocols [
    {:grpc, []},
    {:connect, [adapter_opts: [protocols: [:http1]]]},
    {:connect, [adapter_opts: [protocols: [:http2]]]},
    {:grpc_web, [adapter_opts: [protocols: [:http1]]]},
    {:grpc_web, [adapter_opts: [protocols: [:http2]]]}
  ]

  setup do
    {:ok, _, port} = GRPC.Server.start_endpoint(Conformance.Endpoint, 0)
    on_exit(fn -> GRPC.Server.stop_endpoint(Conformance.Endpoint) end)
    {:ok, channels} = Channels.start_link()
    %{port: port, channels: channels}
  end

  # The server closing the connections of a shared channel (a restart here; GOAWAY or an
  # idle close in a run) must not fail the next case that takes the channel.
  for adapter <- @adapters, {protocol, extra} <- @protocols do
    @tag :capture_log
    test "#{inspect(adapter)} #{protocol} #{inspect(extra)}: the next case works after the server closes the connection",
         %{port: port, channels: channels} do
      opts = [adapter: unquote(adapter), protocol: unquote(protocol)] ++ unquote(extra)
      addr = "127.0.0.1:#{port}"

      assert {:ok, channel} = Channels.checkout(channels, addr, opts)
      assert {:ok, _} = Stub.unary(channel, %UnaryRequest{})

      :ok = GRPC.Server.stop_endpoint(Conformance.Endpoint)
      {:ok, _, ^port} = GRPC.Server.start_endpoint(Conformance.Endpoint, port)

      assert {:ok, ^channel} = Channels.checkout(channels, addr, opts)
      assert {:ok, _} = Stub.unary(channel, %UnaryRequest{})
    end
  end
end
