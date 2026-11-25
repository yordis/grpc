defmodule GRPC.Integration.ConnectClientGetTest do
  use GRPC.Integration.TestCase, async: false

  alias GRPC.Client.Adapters.Gun
  alias GRPC.Client.Adapters.Mint

  defmodule ReadService do
    @moduledoc false
    use GRPC.Service, name: "helloworld.Reader", protoc_gen_elixir_version: "0.17.1"

    rpc(:Read, Helloworld.HelloRequest, Helloworld.HelloReply, %{
      idempotency_level: :NO_SIDE_EFFECTS
    })

    rpc(:Write, Helloworld.HelloRequest, Helloworld.HelloReply)
  end

  defmodule ReadStub do
    use GRPC.Stub, service: ReadService
  end

  defmodule ReadServer do
    use GRPC.Server, service: ReadService, compressors: [GRPC.Compressor.Gzip]

    def read(req, stream) do
      GRPC.Server.set_headers(stream, %{"x-method" => to_string(stream.http_method)})
      %Helloworld.HelloReply{message: "Hello, #{req.name}"}
    end

    def write(req, _stream), do: %Helloworld.HelloReply{message: "Wrote, #{req.name}"}
  end

  def connect(port, adapter, opts) do
    {:ok, channel} =
      GRPC.Stub.connect("localhost:#{port}", [adapter: adapter, protocol: :connect] ++ opts)

    channel
  end

  for adapter <- [Mint, Gun], protocols <- [[:http2], [:http1]] do
    describe "a Connect call with GET with #{inspect(adapter)} over #{inspect(protocols)}" do
      @describetag protocols: protocols, adapter: adapter

      test "reads the reply", %{protocols: protocols, adapter: adapter} do
        run_server(ReadServer, fn port ->
          channel = connect(port, adapter, adapter_opts: [protocols: protocols])

          assert {:ok, %Helloworld.HelloReply{message: "Hello, get"},
                  %{headers: %{"x-method" => "get"}}} =
                   ReadStub.read(channel, %Helloworld.HelloRequest{name: "get"},
                     http_method: :get,
                     return_headers: true
                   )
        end)
      end

      test "compresses the message in the query", %{protocols: protocols, adapter: adapter} do
        run_server(ReadServer, fn port ->
          channel = connect(port, adapter, adapter_opts: [protocols: protocols])

          assert {:ok, %Helloworld.HelloReply{message: "Hello, gzip"},
                  %{headers: %{"x-method" => "get"}}} =
                   ReadStub.read(channel, %Helloworld.HelloRequest{name: "gzip"},
                     http_method: :get,
                     compressor: GRPC.Compressor.Gzip,
                     return_headers: true
                   )
        end)
      end

      test "a call without the option is a POST", %{protocols: protocols, adapter: adapter} do
        run_server(ReadServer, fn port ->
          channel = connect(port, adapter, adapter_opts: [protocols: protocols])

          assert {:ok, _reply, %{headers: %{"x-method" => "post"}}} =
                   ReadStub.read(channel, %Helloworld.HelloRequest{name: "post"},
                     return_headers: true
                   )
        end)
      end
    end
  end
end
