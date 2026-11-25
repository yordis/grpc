defmodule GRPC.Integration.ConnectClientGetTest do
  use GRPC.Integration.TestCase, async: false

  alias GRPC.Client.Adapters.Mint

  defmodule ReadService do
    @moduledoc false
    use GRPC.Service, name: "helloworld.Reader", protoc_gen_elixir_version: "0.17.1"

    rpc(:Read, Helloworld.HelloRequest, Helloworld.HelloReply, %{
      idempotency_level: :NO_SIDE_EFFECTS
    })

    rpc(:Write, Helloworld.HelloRequest, Helloworld.HelloReply)

    rpc(:Watch, Helloworld.HelloRequest, stream(Helloworld.HelloReply), %{
      idempotency_level: :NO_SIDE_EFFECTS
    })
  end

  defmodule ReadStub do
    use GRPC.Stub, service: ReadService
  end

  defmodule ReadServer do
    use GRPC.Server, service: ReadService, connect: true, compressors: [GRPC.Compressor.Gzip]

    def read(req, stream) do
      GRPC.Server.set_headers(stream, %{"x-method" => to_string(stream.http_method)})
      %Helloworld.HelloReply{message: "Hello, #{req.name}"}
    end

    def write(req, _stream), do: %Helloworld.HelloReply{message: "Wrote, #{req.name}"}

    def watch(_req, stream), do: GRPC.Server.send_reply(stream, %Helloworld.HelloReply{})
  end

  def connect(port, opts) do
    {:ok, channel} =
      GRPC.Stub.connect("localhost:#{port}", [adapter: Mint, protocol: :connect] ++ opts)

    channel
  end

  for protocols <- [[:http2], [:http1]] do
    describe "a Connect call with GET over #{inspect(protocols)}" do
      @describetag protocols: protocols

      test "reads the reply", %{protocols: protocols} do
        run_server(ReadServer, fn port ->
          channel = connect(port, adapter_opts: [protocols: protocols])

          assert {:ok, %Helloworld.HelloReply{message: "Hello, get"},
                  %{headers: %{"x-method" => "get"}}} =
                   ReadStub.read(channel, %Helloworld.HelloRequest{name: "get"},
                     http_method: :get,
                     return_headers: true
                   )
        end)
      end

      test "compresses the message in the query", %{protocols: protocols} do
        run_server(ReadServer, fn port ->
          channel = connect(port, adapter_opts: [protocols: protocols])

          assert {:ok, %Helloworld.HelloReply{message: "Hello, gzip"},
                  %{headers: %{"x-method" => "get"}}} =
                   ReadStub.read(channel, %Helloworld.HelloRequest{name: "gzip"},
                     http_method: :get,
                     compressor: GRPC.Compressor.Gzip,
                     return_headers: true
                   )
        end)
      end

      test "a call without the option is a POST", %{protocols: protocols} do
        run_server(ReadServer, fn port ->
          channel = connect(port, adapter_opts: [protocols: protocols])

          assert {:ok, _reply, %{headers: %{"x-method" => "post"}}} =
                   ReadStub.read(channel, %Helloworld.HelloRequest{name: "post"},
                     return_headers: true
                   )
        end)
      end
    end
  end

  describe "the :http_method option" do
    test "a method with side effects refuses :get" do
      run_server(ReadServer, fn port ->
        channel = connect(port, adapter_opts: [protocols: [:http2]])

        assert_raise ArgumentError, ~r/NO_SIDE_EFFECTS/, fn ->
          ReadStub.write(channel, %Helloworld.HelloRequest{name: "x"}, http_method: :get)
        end
      end)
    end

    test "a streaming call refuses :get" do
      run_server(ReadServer, fn port ->
        channel = connect(port, adapter_opts: [protocols: [:http2]])

        assert_raise ArgumentError, ~r/unary/, fn ->
          ReadStub.watch(channel, %Helloworld.HelloRequest{name: "x"}, http_method: :get)
        end
      end)
    end

    test "a channel that is not Connect refuses :get" do
      run_server(ReadServer, fn port ->
        {:ok, channel} = GRPC.Stub.connect("localhost:#{port}", adapter: Mint)

        assert_raise ArgumentError, ~r/protocol: :connect/, fn ->
          ReadStub.read(channel, %Helloworld.HelloRequest{name: "x"}, http_method: :get)
        end
      end)
    end

    test "a value other than :get or :post is refused" do
      run_server(ReadServer, fn port ->
        channel = connect(port, adapter_opts: [protocols: [:http2]])

        for value <- [:put, :GET, "GET", nil] do
          assert_raise ArgumentError, ~r/http_method/, fn ->
            ReadStub.read(channel, %Helloworld.HelloRequest{name: "x"}, http_method: value)
          end
        end
      end)
    end

    test ":post is accepted on any channel" do
      run_server(ReadServer, fn port ->
        {:ok, channel} = GRPC.Stub.connect("localhost:#{port}", adapter: Mint)

        assert {:ok, %Helloworld.HelloReply{}} =
                 ReadStub.read(channel, %Helloworld.HelloRequest{name: "x"}, http_method: :post)
      end)
    end
  end
end
