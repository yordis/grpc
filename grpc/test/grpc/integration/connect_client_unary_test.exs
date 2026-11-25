defmodule GRPC.Integration.ConnectClientUnaryTest do
  use GRPC.Integration.TestCase, async: false

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

  def connect(port, opts \\ []) do
    {:ok, channel} =
      GRPC.Stub.connect(
        "localhost:#{port}",
        [adapter: Mint, protocol: :connect] ++ opts
      )

    channel
  end

  for protocols <- [[:http2], [:http1]] do
    describe "a unary Connect call over #{inspect(protocols)}" do
      @describetag protocols: protocols

      test "returns the reply with the headers and the trailers", %{protocols: protocols} do
        run_server(HelloServer, fn port ->
          channel = connect(port, adapter_opts: [protocols: protocols])

          assert {:ok, %Helloworld.HelloReply{message: "Hello, connect"},
                  %{headers: headers, trailers: trailers}} =
                   Helloworld.Greeter.Stub.say_hello(
                     channel,
                     %Helloworld.HelloRequest{name: "connect"},
                     return_headers: true
                   )

          assert headers["x-custom-header"] == "from-server"
          assert headers["content-type"] == "application/proto"
          assert trailers["x-custom-trailer"] == "from-server-trailer"
          refute Map.has_key?(headers, "trailer-x-custom-trailer")
        end)
      end

      test "returns the error of the server", %{protocols: protocols} do
        run_server(HelloServer, fn port ->
          channel = connect(port, adapter_opts: [protocols: protocols])

          assert {:error, %GRPC.RPCError{status: 5, message: "no such greeting"}} =
                   Helloworld.Greeter.Stub.say_hello(channel, %Helloworld.HelloRequest{name: "fail"})
        end)
      end
    end
  end
end
