defmodule Conformance.Client.ChannelsConcurrencyTest do
  # The endpoint has one name, so the tests take turns.
  use ExUnit.Case, async: false

  alias Connectrpc.Conformance.V1.{
    ClientCompatRequest,
    ConformanceService.Stub,
    UnaryRequest,
    UnaryResponseDefinition
  }

  alias Conformance.Client.{Call, Channels, Main}

  @delay_ms 1_000

  setup do
    {:ok, _, port} = GRPC.Server.start_endpoint(Conformance.Endpoint, 0)
    on_exit(fn -> GRPC.Server.stop_endpoint(Conformance.Endpoint) end)
    {:ok, channels} = Channels.start_link()
    %{port: port, channels: channels}
  end

  # The reference client gives HTTP/1.1 cases a transport with no limit on connections, so
  # no case waits for another. As many slow calls as the client runs at once share one
  # HTTP/1.1 channel, and they all run side by side.
  for adapter <- [GRPC.Client.Adapters.Mint, GRPC.Client.Adapters.Gun],
      protocol <- [:PROTOCOL_CONNECT, :PROTOCOL_GRPC_WEB] do
    test "#{inspect(adapter)} #{protocol}: #{Main.max_in_flight()} slow HTTP/1.1 calls on a shared channel run at once",
         %{port: port, channels: channels} do
      req = %ClientCompatRequest{
        host: "127.0.0.1",
        port: port,
        protocol: unquote(protocol),
        http_version: :HTTP_VERSION_1,
        codec: :CODEC_PROTO
      }

      assert Channels.shared?(req)
      opts = Call.connect_opts(req, unquote(adapter))
      assert {:ok, channel} = Channels.checkout(channels, "127.0.0.1:#{port}", opts)

      slow = %UnaryRequest{
        response_definition: %UnaryResponseDefinition{response_delay_ms: @delay_ms}
      }

      started = System.monotonic_time(:millisecond)

      results =
        1..Main.max_in_flight()
        |> Task.async_stream(fn _ -> Stub.unary(channel, slow, timeout: 10_000) end,
          max_concurrency: Main.max_in_flight(),
          timeout: 15_000
        )
        |> Enum.map(fn {:ok, result} -> result end)

      elapsed = System.monotonic_time(:millisecond) - started

      assert Enum.all?(results, &match?({:ok, _}, &1)), inspect(results)
      assert elapsed < 3 * @delay_ms, "took #{elapsed} ms"
    end
  end
end
