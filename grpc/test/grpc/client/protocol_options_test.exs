defmodule GRPC.Client.ProtocolOptionsTest do
  use ExUnit.Case, async: true

  alias GRPC.Client.Adapters.{Gun, Mint}

  @h2_preface "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"

  defmodule ConnectAdapter do
    @moduledoc false
    @behaviour GRPC.Client.Adapter

    def supported_protocols, do: [:grpc, :connect]

    def connect(channel, _opts), do: {:ok, channel}
    def disconnect(channel), do: {:ok, channel}
    def send_request(stream, _message, _opts), do: stream
    def receive_data(_stream, _opts), do: {:ok, nil}
    def send_data(stream, _message, _opts), do: stream
    def send_headers(stream, _opts), do: stream
    def end_stream(stream), do: stream
    def cancel(stream), do: stream
  end

  # What the first bytes of a plaintext connection say about the HTTP version the client speaks.
  # A listener that never answers shows it: HTTP/2 opens with its preface, HTTP/1.1 with the
  # request line of the first call.
  defp first_bytes(adapter, protocol, adapter_opts) do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listener)

    client =
      Task.async(fn ->
        with {:ok, channel} <-
               GRPC.Stub.connect("localhost:#{port}",
                 adapter: adapter,
                 protocol: protocol,
                 adapter_opts: adapter_opts
               ) do
          Helloworld.Greeter.Stub.say_hello(channel, %Helloworld.HelloRequest{name: "x"},
            timeout: 500
          )
        end
      end)

    {:ok, socket} = :gen_tcp.accept(listener, 5_000)
    {:ok, bytes} = :gen_tcp.recv(socket, 0, 5_000)

    :gen_tcp.close(socket)
    :gen_tcp.close(listener)
    Task.shutdown(client, :brutal_kill)
    bytes
  end

  for adapter <- [Mint, Gun], protocol <- [:connect, :grpc_web] do
    describe "#{inspect(adapter)} with protocol: #{inspect(protocol)} on http://" do
      @describetag adapter: adapter, protocol: protocol

      test "speaks HTTP/2 with prior knowledge by default", %{adapter: adapter, protocol: protocol} do
        assert first_bytes(adapter, protocol, []) =~ @h2_preface
      end

      test "speaks HTTP/2 when both versions are allowed, as plaintext has no ALPN", %{
        adapter: adapter,
        protocol: protocol
      } do
        assert first_bytes(adapter, protocol, protocols: [:http1, :http2]) =~ @h2_preface
        assert first_bytes(adapter, protocol, protocols: [:http2, :http1]) =~ @h2_preface
      end

      test "speaks HTTP/1.1 only when asked", %{adapter: adapter, protocol: protocol} do
        assert "POST /" <> _ = first_bytes(adapter, protocol, protocols: [:http1])
      end
    end
  end

  for adapter <- [Mint, Gun] do
    describe "#{inspect(adapter)} :protocols option" do
      @describetag adapter: adapter

      test "rejects a value that is not a list of :http1 and :http2", %{adapter: adapter} do
        for bad <- [[:h2], [], :http2, [:http2, :http2], [:http1, "http2"]] do
          assert_raise ArgumentError, ~r/protocols/, fn ->
            GRPC.Stub.connect("localhost:1",
              adapter: adapter,
              protocol: :connect,
              adapter_opts: [protocols: bad]
            )
          end
        end
      end

      test "is rejected with protocol: :grpc", %{adapter: adapter} do
        assert_raise ArgumentError, ~r/protocols.*:grpc|:grpc.*protocols/, fn ->
          GRPC.Stub.connect("localhost:1",
            adapter: adapter,
            adapter_opts: [protocols: [:http1]]
          )
        end
      end
    end
  end

  describe "an adapter that declares its protocols" do
    test "takes the protocols it lists" do
      assert {:ok, %GRPC.Channel{protocol: :connect}} =
               GRPC.Stub.connect("localhost:1", adapter: ConnectAdapter, protocol: :connect)
    end

    test "does not take the protocols it does not list" do
      assert_raise ArgumentError, ~r/grpc_web/, fn ->
        GRPC.Stub.connect("localhost:1", adapter: ConnectAdapter, protocol: :grpc_web)
      end
    end

    test "an adapter that declares nothing takes :grpc only" do
      assert_raise ArgumentError, ~r/connect/, fn ->
        GRPC.Stub.connect("localhost:1", adapter: GRPC.Test.ClientAdapter, protocol: :connect)
      end
    end
  end
end
