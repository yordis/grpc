defmodule GRPC.Integration.ClientMetadataTest do
  use ExUnit.Case, async: true

  alias GRPC.Client.Adapters.{Gun, Mint}
  alias GRPC.Integration.ScriptedH2Server

  defp frame(message) do
    body = Protobuf.encode(message)
    <<0, byte_size(body)::32, body::binary>>
  end

  defp connect(port, adapter) do
    channel = ScriptedH2Server.connect(port, adapter)
    channel
  end

  @headers [
    {":status", "200"},
    {"content-type", "application/grpc"},
    {"x-custom-header", "foo"},
    {"x-custom-header", "bar"},
    {"x-custom-header", "baz"}
  ]

  @trailers [
    {"grpc-status", "0"},
    {"x-custom-trailer", "one"},
    {"x-custom-trailer", "two"}
  ]

  for adapter <- [Gun, Mint] do
    describe "with the #{inspect(adapter)} adapter" do
      @describetag adapter: adapter

      test "a repeated response header and trailer of a unary call keep every value",
           %{adapter: adapter} do
        port =
          ScriptedH2Server.start([
            {:headers, @headers},
            {:data, frame(%Helloworld.HelloReply{message: "hi"})},
            {:headers, @trailers, :fin}
          ])

        channel = connect(port, adapter)

        assert {:ok, %Helloworld.HelloReply{}, %{headers: headers, trailers: trailers}} =
                 Helloworld.Greeter.Stub.say_hello(channel, %Helloworld.HelloRequest{name: "x"},
                   return_headers: true
                 )

        assert headers["x-custom-header"] == "foo,bar,baz"
        assert trailers["x-custom-trailer"] == "one,two"
      end

      test "a repeated response header and trailer of a server stream keep every value",
           %{adapter: adapter} do
        port =
          ScriptedH2Server.start([
            {:headers, @headers},
            {:data, frame(%Routeguide.Feature{name: "a"})},
            {:headers, @trailers, :fin}
          ])

        channel = connect(port, adapter)

        {:ok, replies, %{headers: headers}} =
          Routeguide.RouteGuide.Stub.list_features(channel, %Routeguide.Rectangle{},
            return_headers: true
          )

        assert headers["x-custom-header"] == "foo,bar,baz"

        assert [{:ok, %Routeguide.Feature{name: "a"}}, {:trailers, trailers}] =
                 Enum.to_list(replies)

        assert trailers["x-custom-trailer"] == "one,two"
      end

      test "a binary header value is decoded with or without padding", %{adapter: adapter} do
        port =
          ScriptedH2Server.start([
            {:headers,
             [
               {":status", "200"},
               {"content-type", "application/grpc"},
               {"x-padded-bin", Base.encode64("a", padding: true)},
               {"x-unpadded-bin", Base.encode64("a", padding: false)}
             ]},
            {:data, frame(%Helloworld.HelloReply{message: "hi"})},
            {:headers, [{"grpc-status", "0"}], :fin}
          ])

        channel = connect(port, adapter)

        assert {:ok, _reply, %{headers: headers}} =
                 Helloworld.Greeter.Stub.say_hello(channel, %Helloworld.HelloRequest{name: "x"},
                   return_headers: true
                 )

        assert headers["x-padded-bin"] == "a"
        assert headers["x-unpadded-bin"] == "a"
      end

      test "a binary request metadata value is sent without padding", %{adapter: adapter} do
        port =
          ScriptedH2Server.start(
            [
              {:headers, [{":status", "200"}, {"content-type", "application/grpc"}]},
              {:data, frame(%Helloworld.HelloReply{message: "hi"})},
              {:headers, [{"grpc-status", "0"}], :fin}
            ],
            notify: self()
          )

        channel = connect(port, adapter)

        assert {:ok, _reply} =
                 Helloworld.Greeter.Stub.say_hello(channel, %Helloworld.HelloRequest{name: "x"},
                   metadata: %{"x-trace-bin" => "a"}
                 )

        assert_receive {:request_headers, headers}
        assert {"x-trace-bin", "YQ"} in headers
      end
    end
  end
end
