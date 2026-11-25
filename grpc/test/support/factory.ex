defmodule GRPC.Factory do
  @moduledoc false

  alias GRPC.Channel

  def build(resource, attrs \\ %{}) do
    name = :"#{resource}_factory"

    attrs = Map.new(attrs)

    data =
      if function_exported?(__MODULE__, name, 1) do
        apply(__MODULE__, name, [attrs])
      else
        apply(__MODULE__, name, [])
      end

    Map.merge(data, attrs)
  end

  def channel_factory do
    %Channel{
      host: "localhost",
      port: 1337,
      scheme: "http",
      cred: GRPC.TestCerts.client_credential(),
      adapter: GRPC.Client.Adapters.Gun,
      adapter_payload: %{},
      codec: GRPC.Codec.Proto,
      interceptors: [],
      compressor: nil,
      accepted_compressors: [],
      headers: []
    }
  end

  def client_stream_factory do
    %GRPC.Client.Stream{
      __interface__: %{
        receive_data: &GRPC.Client.Stream.receive_data/2,
        send_request: &GRPC.Client.Stream.send_request/3
      },
      canceled: false,
      channel: build(:channel, adapter: GRPC.Client.Adapters.Mint),
      codec: GRPC.Codec.Proto,
      compressor: nil,
      grpc_type: :unary,
      headers: %{},
      method_name: "SayHello",
      path: "/helloworld.Greeter/SayHello",
      payload: %{},
      request_mod: Helloworld.HelloRequest,
      response_mod: Helloworld.HelloReply,
      rpc: {"say_hello", {Helloworld.HelloRequest, false}, {Helloworld.HelloReply, false}},
      server_stream: false,
      service_name: "helloworld.Greeter",
      accepted_compressors: [GRPC.Compressor.Gzip]
    }
  end

  def hello_reply_rpc_factory do
    %Helloworld.HelloReply{message: "Hello Luis"}
  end

  def bye_reply_rpc_factory do
    %Helloworld.HelloReply{message: "Bye Luis"}
  end
end
