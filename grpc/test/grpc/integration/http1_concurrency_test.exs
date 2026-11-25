defmodule GRPC.Integration.Http1ConcurrencyTest do
  # HTTP/1.1 carries one call at a time on a connection. Calls in parallel on one channel
  # must not break each other: a cancel or a deadline ends only its own call, and a call
  # that is open does not make the others fail.
  use GRPC.Integration.TestCase, async: false

  alias GRPC.Client.Adapters.{Gun, Mint}
  alias GRPC.RPCError

  @cancelled GRPC.Status.cancelled()
  @deadline_exceeded GRPC.Status.deadline_exceeded()

  defmodule HelloServer do
    use GRPC.Server, service: Helloworld.Greeter.Service, connect: true

    def say_hello(%{name: "hang"}, _stream) do
      Process.sleep(10_000)
      %Helloworld.HelloReply{message: "late"}
    end

    def say_hello(%{name: "slow"}, _stream) do
      Process.sleep(600)
      %Helloworld.HelloReply{message: "Hello, slow"}
    end

    def say_hello(req, _stream), do: %Helloworld.HelloReply{message: "Hello, #{req.name}"}
  end

  defmodule RouteServer do
    use GRPC.Server, service: Routeguide.RouteGuide.Service, connect: true

    def record_route(req_enum, _stream),
      do: %Routeguide.RouteSummary{point_count: Enum.count(req_enum)}

    def list_features(_rect, stream) do
      GRPC.Server.send_reply(stream, %Routeguide.Feature{name: "first"})
      Process.sleep(5_000)
      GRPC.Server.send_reply(stream, %Routeguide.Feature{name: "last"})
    end
  end

  setups = [
    {"Mint with Connect", [adapter: Mint, protocol: :connect]},
    {"Mint with gRPC-Web", [adapter: Mint, protocol: :grpc_web]},
    {"Gun with Connect", [adapter: Gun, protocol: :connect]},
    {"Gun with gRPC-Web", [adapter: Gun, protocol: :grpc_web]}
  ]

  defp connect(port, connect_opts) do
    {:ok, channel} =
      GRPC.Stub.connect(
        "localhost:#{port}",
        connect_opts ++ [adapter_opts: [protocols: [:http1]]]
      )

    channel
  end

  defp hello(channel, name, opts \\ []),
    do: Helloworld.Greeter.Stub.say_hello(channel, %Helloworld.HelloRequest{name: name}, opts)

  for {name, connect_opts} <- setups do
    describe "#{name} over HTTP/1.1" do
      @describetag connect_opts: connect_opts

      test "cancelling one call does not fail the call next to it", %{connect_opts: connect_opts} do
        run_server([HelloServer, RouteServer], fn port ->
          channel = connect(port, connect_opts)
          handle = GRPC.Stub.new_cancel_handle()

          hung = Task.async(fn -> hello(channel, "hang", cancel: handle) end)
          Process.sleep(100)
          slow = Task.async(fn -> hello(channel, "slow", timeout: 5_000) end)
          Process.sleep(100)

          assert :ok = GRPC.Stub.cancel(handle)

          assert {:error, %RPCError{status: @cancelled}} = Task.await(hung, 5_000)
          assert {:ok, %Helloworld.HelloReply{message: "Hello, slow"}} = Task.await(slow, 5_000)
          assert {:ok, %Helloworld.HelloReply{message: "Hello, after"}} = hello(channel, "after")
        end)
      end

      test "a deadline on one call does not fail the call next to it", %{
        connect_opts: connect_opts
      } do
        run_server([HelloServer, RouteServer], fn port ->
          channel = connect(port, connect_opts)

          hung = Task.async(fn -> hello(channel, "hang", timeout: 300) end)
          Process.sleep(100)
          slow = Task.async(fn -> hello(channel, "slow", timeout: 5_000) end)

          assert {:error, %RPCError{status: @deadline_exceeded}} = Task.await(hung, 5_000)
          assert {:ok, %Helloworld.HelloReply{message: "Hello, slow"}} = Task.await(slow, 5_000)
          assert {:ok, %Helloworld.HelloReply{message: "Hello, after"}} = hello(channel, "after")
        end)
      end

      test "the channel serves calls after a call was cancelled", %{connect_opts: connect_opts} do
        run_server([HelloServer, RouteServer], fn port ->
          channel = connect(port, connect_opts)

          for _ <- 1..3 do
            assert {:error, %RPCError{status: @deadline_exceeded}} =
                     hello(channel, "hang", timeout: 200)

            assert {:ok, %Helloworld.HelloReply{message: "Hello, again"}} =
                     hello(channel, "again")
          end
        end)
      end

      test "a call goes through while a client stream is open", %{connect_opts: connect_opts} do
        run_server([HelloServer, RouteServer], fn port ->
          channel = connect(port, connect_opts)

          stream = Routeguide.RouteGuide.Stub.record_route(channel)
          GRPC.Stub.send_request(stream, %Routeguide.Point{})

          assert {:ok, %Helloworld.HelloReply{message: "Hello, beside"}} =
                   hello(channel, "beside", timeout: 2_000)

          GRPC.Stub.send_request(stream, %Routeguide.Point{}, end_stream: true)
          assert {:ok, %Routeguide.RouteSummary{point_count: 2}} = GRPC.Stub.recv(stream)
        end)
      end

      test "a call goes through while a server stream is open", %{connect_opts: connect_opts} do
        run_server([HelloServer, RouteServer], fn port ->
          channel = connect(port, connect_opts)

          assert {:ok, replies} =
                   Routeguide.RouteGuide.Stub.list_features(channel, %Routeguide.Rectangle{})

          assert [{:ok, %Routeguide.Feature{name: "first"}}] = Enum.take(replies, 1)

          assert {:ok, %Helloworld.HelloReply{message: "Hello, beside"}} =
                   hello(channel, "beside", timeout: 2_000)
        end)
      end
    end
  end
end
