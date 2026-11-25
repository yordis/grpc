defmodule GRPC.Integration.Http1ConcurrencyTest do
  # HTTP/1.1 carries one call at a time on a connection. Calls in parallel on one channel
  # must not break each other: a cancel or a deadline ends only its own call, and a call
  # that is open does not make the others fail.
  use GRPC.Integration.TestCase, async: false

  alias GRPC.Client.Adapters.{Gun, Mint}
  alias GRPC.RPCError

  @cancelled GRPC.Status.cancelled()
  @deadline_exceeded GRPC.Status.deadline_exceeded()

  defmodule Gauge do
    @moduledoc false
    # {calls being served now, most calls served at once}
    def start_link(_opts), do: Agent.start_link(fn -> {0, 0} end, name: __MODULE__)
    def child_spec(opts), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}

    def enter, do: Agent.update(__MODULE__, fn {now, max} -> {now + 1, max(max, now + 1)} end)
    def leave, do: Agent.update(__MODULE__, fn {now, max} -> {now - 1, max} end)
    def read, do: Agent.get(__MODULE__, & &1)
  end

  defmodule HelloServer do
    use GRPC.Server, service: Helloworld.Greeter.Service, connect: true

    def say_hello(%{name: "gauge"}, _stream) do
      Gauge.enter()
      Process.sleep(400)
      Gauge.leave()
      %Helloworld.HelloReply{message: "Hello, gauge"}
    end

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

  defp connect(port, connect_opts, adapter_opts \\ []) do
    {:ok, channel} =
      GRPC.Stub.connect(
        "localhost:#{port}",
        connect_opts ++ [adapter_opts: [protocols: [:http1]] ++ adapter_opts]
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

      test "opens at most :http1_max_connections connections", %{connect_opts: connect_opts} do
        start_supervised!(Gauge)

        run_server([HelloServer, RouteServer], fn port ->
          channel = connect(port, connect_opts, http1_max_connections: 2)

          results =
            1..6
            |> Enum.map(fn _ ->
              Task.async(fn -> hello(channel, "gauge", timeout: 10_000) end)
            end)
            |> Task.await_many(15_000)

          for result <- results,
              do: assert({:ok, %Helloworld.HelloReply{message: "Hello, gauge"}} = result)

          assert {0, 2} = Gauge.read()
        end)
      end

      test "rejects an :http1_max_connections that is not a positive integer", %{
        connect_opts: connect_opts
      } do
        for value <- [0, -1, 1.5, :many, nil] do
          assert_raise ArgumentError, ~r/http1_max_connections/, fn ->
            GRPC.Stub.connect(
              "localhost:1",
              connect_opts ++ [adapter_opts: [protocols: [:http1], http1_max_connections: value]]
            )
          end
        end
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
