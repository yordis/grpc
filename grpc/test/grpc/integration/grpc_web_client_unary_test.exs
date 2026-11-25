defmodule GRPC.Integration.GrpcWebClientUnaryTest do
  use GRPC.Integration.TestCase, async: false

  alias GRPC.Client.Adapters.Gun
  alias GRPC.Client.Adapters.Mint

  defmodule HelloServer do
    use GRPC.Server, service: Helloworld.Greeter.Service, compressors: [GRPC.Compressor.Gzip]

    def say_hello(%{name: "fail"}, _stream) do
      raise GRPC.RPCError, status: :not_found, message: "no such greeting"
    end

    def say_hello(req, stream) do
      GRPC.Server.set_headers(stream, %{"x-custom-header" => "from-server"})
      GRPC.Server.set_trailers(stream, %{"x-custom-trailer" => "from-server-trailer"})

      %Helloworld.HelloReply{message: "Hello, #{req.name}"}
    end
  end

  def connect(port, adapter, opts) do
    {:ok, channel} =
      GRPC.Stub.connect(
        "localhost:#{port}",
        [adapter: adapter, protocol: :grpc_web] ++ opts
      )

    channel
  end

  for adapter <- [Mint, Gun], protocols <- [[:http2], [:http1]] do
    describe "a unary gRPC-Web call with #{inspect(adapter)} over #{inspect(protocols)}" do
      @describetag protocols: protocols, adapter: adapter

      test "returns the reply with the headers and the trailers", %{
        protocols: protocols,
        adapter: adapter
      } do
        run_server(HelloServer, fn port ->
          channel = connect(port, adapter, adapter_opts: [protocols: protocols])

          assert {:ok, %Helloworld.HelloReply{message: "Hello, connect"},
                  %{headers: headers, trailers: trailers}} =
                   Helloworld.Greeter.Stub.say_hello(
                     channel,
                     %Helloworld.HelloRequest{name: "connect"},
                     return_headers: true
                   )

          assert headers["x-custom-header"] == "from-server"
          assert headers["content-type"] == "application/grpc-web+proto"
          assert trailers["x-custom-trailer"] == "from-server-trailer"
          refute Map.has_key?(headers, "trailer-x-custom-trailer")
        end)
      end

      test "returns the error of the server", %{protocols: protocols, adapter: adapter} do
        run_server(HelloServer, fn port ->
          channel = connect(port, adapter, adapter_opts: [protocols: protocols])

          assert {:error, %GRPC.RPCError{status: 5, message: "no such greeting"}} =
                   Helloworld.Greeter.Stub.say_hello(channel, %Helloworld.HelloRequest{
                     name: "fail"
                   })
        end)
      end

      test "compresses the request", %{protocols: protocols, adapter: adapter} do
        run_server(HelloServer, fn port ->
          channel = connect(port, adapter, adapter_opts: [protocols: protocols])

          assert {:ok, %Helloworld.HelloReply{message: "Hello, compressed"}} =
                   Helloworld.Greeter.Stub.say_hello(
                     channel,
                     %Helloworld.HelloRequest{name: "compressed"},
                     compressor: GRPC.Compressor.Gzip
                   )
        end)
      end
    end
  end
end
