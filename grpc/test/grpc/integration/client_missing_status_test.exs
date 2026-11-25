defmodule GRPC.Integration.ClientMissingStatusTest do
  use ExUnit.Case, async: true

  alias GRPC.Client.Adapters.{Gun, Mint}
  alias GRPC.Integration.ScriptedH2Server

  @internal GRPC.Status.internal()
  @unknown GRPC.Status.unknown()

  @ok_headers [{":status", "200"}, {"content-type", "application/grpc"}]

  defp frame(message) do
    body = Protobuf.encode(message)
    <<0, byte_size(body)::32, body::binary>>
  end

  defp connect(port, adapter) do
    {:ok, channel} = GRPC.Stub.connect("localhost:#{port}", adapter: adapter)
    channel
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

      test "a unary reply that ends without trailers is an error", %{adapter: adapter} do
        port =
          ScriptedH2Server.start([
            {:headers, @ok_headers},
            {:data, frame(%Helloworld.HelloReply{message: "hi"}), :fin}
          ])

        channel = connect(port, adapter)

        assert {:error, %GRPC.RPCError{status: status}} =
                 Helloworld.Greeter.Stub.say_hello(channel, %Helloworld.HelloRequest{name: "x"})

        assert status in [@internal, @unknown]
      end

      test "a unary reply with headers only and no grpc-status is an error", %{adapter: adapter} do
        port = ScriptedH2Server.start([{:headers, @ok_headers, :fin}])
        channel = connect(port, adapter)

        assert {:error, %GRPC.RPCError{status: status}} =
                 Helloworld.Greeter.Stub.say_hello(channel, %Helloworld.HelloRequest{name: "x"})

        assert status in [@internal, @unknown]
      end

      test "a server stream that ends without trailers yields its messages then an error",
           %{adapter: adapter} do
        port =
          ScriptedH2Server.start([
            {:headers, @ok_headers},
            {:data, frame(%Routeguide.Feature{name: "a"}), :fin}
          ])

        channel = connect(port, adapter)

        {:ok, replies} =
          Routeguide.RouteGuide.Stub.list_features(channel, %Routeguide.Rectangle{})

        assert [{:ok, %Routeguide.Feature{name: "a"}}, {:error, %GRPC.RPCError{status: status}}] =
                 Enum.to_list(replies)

        assert status in [@internal, @unknown]
      end

      test "a server stream that ends in the middle of a message is an error",
           %{adapter: adapter} do
        <<head::binary-size(4), _::binary>> = frame(%Routeguide.Feature{name: "abcdef"})

        port =
          ScriptedH2Server.start([
            {:headers, @ok_headers},
            {:data, head, :fin}
          ])

        channel = connect(port, adapter)

        error =
          stream_error(Routeguide.RouteGuide.Stub.list_features(channel, %Routeguide.Rectangle{}))

        assert %GRPC.RPCError{status: status} = error
        assert status in [@internal, @unknown]
      end

      test "a server stream that ends with headers only and no grpc-status is an error",
           %{adapter: adapter} do
        port =
          ScriptedH2Server.start([
            {:headers, @ok_headers},
            {:data, frame(%Routeguide.Feature{name: "a"})},
            {:headers, [{"x-other", "1"}], :fin}
          ])

        channel = connect(port, adapter)

        error =
          stream_error(Routeguide.RouteGuide.Stub.list_features(channel, %Routeguide.Rectangle{}))

        assert %GRPC.RPCError{status: status} = error
        assert status in [@internal, @unknown]
      end
    end
  end
end
