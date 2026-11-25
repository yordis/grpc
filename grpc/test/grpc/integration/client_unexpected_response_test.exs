defmodule GRPC.Integration.ClientUnexpectedResponseTest do
  use ExUnit.Case, async: true

  alias GRPC.Client.Adapters.{Gun, Mint}
  alias GRPC.Integration.ScriptedH2Server

  @internal GRPC.Status.internal()
  @unknown GRPC.Status.unknown()
  @unimplemented GRPC.Status.unimplemented()

  @ok_headers [{":status", "200"}, {"content-type", "application/grpc"}]
  @ok_trailers [{"grpc-status", "0"}]

  defp frame(message) do
    body = Protobuf.encode(message)
    <<0, byte_size(body)::32, body::binary>>
  end

  defp connect(port, adapter) do
    channel = ScriptedH2Server.connect(port, adapter)
    channel
  end

  defp unary(channel),
    do: Helloworld.Greeter.Stub.say_hello(channel, %Helloworld.HelloRequest{name: "x"})

  defp client_stream(channel) do
    stream = Routeguide.RouteGuide.Stub.record_route(channel)
    stream = GRPC.Stub.send_request(stream, %Routeguide.Point{}, end_stream: true)
    GRPC.Stub.recv(stream)
  end

  defp stream_error(result) do
    case result do
      {:error, error} ->
        error

      {:ok, replies} ->
        Enum.find_value(replies, fn
          {:error, e} -> e
          _ -> nil
        end)
    end
  end

  for adapter <- [Gun, Mint] do
    describe "with the #{inspect(adapter)} adapter" do
      @describetag adapter: adapter

      test "a unary reply with an OK status and no message is unimplemented", %{adapter: adapter} do
        port = ScriptedH2Server.start([{:headers, @ok_headers}, {:headers, @ok_trailers, :fin}])

        assert {:error, %GRPC.RPCError{status: @unimplemented}} =
                 adapter |> then(&connect(port, &1)) |> unary()
      end

      test "a client stream reply with an OK status and no message is unimplemented",
           %{adapter: adapter} do
        port = ScriptedH2Server.start([{:headers, @ok_headers}, {:headers, @ok_trailers, :fin}])

        assert {:error, %GRPC.RPCError{status: @unimplemented}} =
                 adapter |> then(&connect(port, &1)) |> client_stream()
      end

      test "a unary reply with more than one message is an error", %{adapter: adapter} do
        msg = frame(%Helloworld.HelloReply{message: "hi"})

        port =
          ScriptedH2Server.start([
            {:headers, @ok_headers},
            {:data, msg <> msg},
            {:headers, @ok_trailers, :fin}
          ])

        assert {:error, %GRPC.RPCError{status: status}} =
                 adapter |> then(&connect(port, &1)) |> unary()

        assert status == @unimplemented
      end

      test "a client stream reply with more than one message is an error", %{adapter: adapter} do
        msg = frame(%Routeguide.RouteSummary{point_count: 1})

        port =
          ScriptedH2Server.start([
            {:headers, @ok_headers},
            {:data, msg <> msg},
            {:headers, @ok_trailers, :fin}
          ])

        assert {:error, %GRPC.RPCError{status: status}} =
                 adapter |> then(&connect(port, &1)) |> client_stream()

        assert status == @unimplemented
      end

      test "a server stream cut in the middle of a message, then trailers, is an error",
           %{adapter: adapter} do
        <<head::binary-size(8), _::binary>> = frame(%Routeguide.Feature{name: "abcdef"})

        port =
          ScriptedH2Server.start([
            {:headers, @ok_headers},
            {:data, head},
            {:headers, @ok_trailers, :fin}
          ])

        channel = connect(port, adapter)

        error =
          stream_error(Routeguide.RouteGuide.Stub.list_features(channel, %Routeguide.Rectangle{}))

        assert %GRPC.RPCError{status: status} = error
        assert status in [@internal, @unknown]
      end

      test "a reply in another codec than the request is an error, not a crash", %{
        adapter: adapter
      } do
        body = ~s({"payload": {"data": "dGVzdCByZXNwb25zZQ"}})
        framed = <<0, byte_size(body)::32, body::binary>>

        port =
          ScriptedH2Server.start([
            {:headers, [{":status", "200"}, {"content-type", "application/grpc+json"}]},
            {:data, framed},
            {:headers, @ok_trailers, :fin}
          ])

        assert {:error, %GRPC.RPCError{}} = adapter |> then(&connect(port, &1)) |> unary()
      end

      test "a reply that is not application/grpc is unknown", %{adapter: adapter} do
        msg = frame(%Helloworld.HelloReply{message: "hi"})

        port =
          ScriptedH2Server.start([
            {:headers, [{":status", "200"}, {"content-type", "text/plain"}]},
            {:data, msg},
            {:headers, @ok_trailers, :fin}
          ])

        assert {:error, %GRPC.RPCError{status: @unknown}} =
                 adapter |> then(&connect(port, &1)) |> unary()
      end
    end
  end
end
