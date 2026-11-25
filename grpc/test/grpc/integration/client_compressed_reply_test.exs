defmodule GRPC.Integration.ClientCompressedReplyTest do
  use ExUnit.Case, async: true

  alias GRPC.Client.Adapters.{Gun, Mint}
  alias GRPC.Integration.ScriptedH2Server

  defp gzipped(message) do
    body = :zlib.gzip(Protobuf.encode(message))
    <<1, byte_size(body)::32, body::binary>>
  end

  defp script(messages) do
    headers = [
      {":status", "200"},
      {"content-type", "application/grpc"},
      {"grpc-encoding", "gzip"}
    ]

    [{:headers, headers}] ++
      Enum.map(messages, &{:data, gzipped(&1)}) ++
      [{:headers, [{"grpc-status", "0"}], :fin}]
  end

  defp connect(port, adapter) do
    ScriptedH2Server.connect(port, adapter, accepted_compressors: [GRPC.Compressor.Gzip])
  end

  for adapter <- [Gun, Mint] do
    describe "with the #{inspect(adapter)} adapter" do
      @describetag adapter: adapter

      test "a unary reply compressed by the server is decompressed", %{adapter: adapter} do
        port = ScriptedH2Server.start(script([%Helloworld.HelloReply{message: "hi"}]))
        channel = connect(port, adapter)

        assert {:ok, %Helloworld.HelloReply{message: "hi"}} =
                 Helloworld.Greeter.Stub.say_hello(channel, %Helloworld.HelloRequest{name: "x"})
      end

      test "server stream replies compressed by the server are decompressed", %{adapter: adapter} do
        features = [%Routeguide.Feature{name: "a"}, %Routeguide.Feature{name: "b"}]
        port = ScriptedH2Server.start(script(features))
        channel = connect(port, adapter)

        {:ok, replies} =
          Routeguide.RouteGuide.Stub.list_features(channel, %Routeguide.Rectangle{})

        assert [{:ok, %Routeguide.Feature{name: "a"}}, {:ok, %Routeguide.Feature{name: "b"}}] =
                 Enum.to_list(replies)
      end

      test "bidi stream replies compressed by the server are decompressed", %{adapter: adapter} do
        port = ScriptedH2Server.start(script([%Routeguide.RouteNote{message: "a"}]))
        channel = connect(port, adapter)

        stream = Routeguide.RouteGuide.Stub.route_chat(channel)

        stream =
          GRPC.Stub.send_request(stream, %Routeguide.RouteNote{message: "x"}, end_stream: true)

        {:ok, replies} = GRPC.Stub.recv(stream)

        assert [{:ok, %Routeguide.RouteNote{message: "a"}}] = Enum.to_list(replies)
      end
    end
  end
end
