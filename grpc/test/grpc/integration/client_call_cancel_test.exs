defmodule GRPC.Integration.ClientCallCancelTest do
  # Cancels unary and server-streaming calls that are in flight, through a handle
  # given to the call.
  use GRPC.Integration.TestCase, async: false

  alias GRPC.Client.Adapters.{Gun, Mint}
  alias GRPC.RPCError

  @canceled GRPC.Status.cancelled()
  @reset_wait 3_000

  defmodule HelloServer do
    use GRPC.Server, service: Helloworld.Greeter.Service, connect: true

    # Reports its process, then never answers.
    def say_hello(%{name: "echo"}, _stream), do: %Helloworld.HelloReply{message: "Hello, echo"}

    def say_hello(_req, _stream) do
      send(Application.fetch_env!(:grpc, :cancel_test_pid), {:handler, self()})
      Process.sleep(:infinity)
    end
  end

  defmodule RouteServer do
    use GRPC.Server, service: Routeguide.RouteGuide.Service, connect: true

    # Sends two features, reports its process, then keeps the stream open.
    def list_features(_rect, stream) do
      send(Application.fetch_env!(:grpc, :cancel_test_pid), {:handler, self()})
      GRPC.Server.send_reply(stream, %Routeguide.Feature{name: "one"})
      GRPC.Server.send_reply(stream, %Routeguide.Feature{name: "two"})
      Process.sleep(:infinity)
    end
  end

  setup do
    Application.put_env(:grpc, :cancel_test_pid, self())
    on_exit(fn -> Application.delete_env(:grpc, :cancel_test_pid) end)
  end

  setups = [
    {"Gun with gRPC", [adapter: Gun]},
    {"Mint with gRPC", [adapter: Mint]},
    {"Mint with Connect over HTTP/2",
     [adapter: Mint, protocol: :connect, adapter_opts: [protocols: [:http2]]]},
    {"Mint with Connect over HTTP/1.1",
     [adapter: Mint, protocol: :connect, adapter_opts: [protocols: [:http1]]]}
  ]

  for {name, connect_opts} <- setups do
    describe name do
      @describetag connect_opts: connect_opts

      test "a unary call cancelled in flight fails with CANCELED and the server sees the reset",
           %{connect_opts: connect_opts} do
        run_server(HelloServer, fn port ->
          {:ok, channel} = GRPC.Stub.connect("localhost:#{port}", connect_opts)
          handle = GRPC.Stub.new_cancel_handle()

          caller =
            Task.async(fn ->
              Helloworld.Greeter.Stub.say_hello(channel, %Helloworld.HelloRequest{name: "x"},
                cancel: handle
              )
            end)

          assert_receive {:handler, handler}, @reset_wait
          ref = Process.monitor(handler)

          assert :ok = GRPC.Stub.cancel(handle)

          assert {:error, %RPCError{status: @canceled}} = Task.await(caller, @reset_wait)
          assert_receive {:DOWN, ^ref, :process, ^handler, _}, @reset_wait
        end)
      end

      test "a unary call cancelled before it starts fails with CANCELED",
           %{connect_opts: connect_opts} do
        run_server(HelloServer, fn port ->
          {:ok, channel} = GRPC.Stub.connect("localhost:#{port}", connect_opts)
          handle = GRPC.Stub.new_cancel_handle()
          assert :ok = GRPC.Stub.cancel(handle)

          assert {:error, %RPCError{status: @canceled}} =
                   Helloworld.Greeter.Stub.say_hello(channel, %Helloworld.HelloRequest{name: "x"},
                     cancel: handle
                   )
        end)
      end

      test "cancelling a call that has finished is a no-op", %{connect_opts: connect_opts} do
        run_server(HelloServer, fn port ->
          {:ok, channel} = GRPC.Stub.connect("localhost:#{port}", connect_opts)
          handle = GRPC.Stub.new_cancel_handle()

          assert {:ok, %Helloworld.HelloReply{message: "Hello, echo"}} =
                   Helloworld.Greeter.Stub.say_hello(
                     channel,
                     %Helloworld.HelloRequest{name: "echo"},
                     cancel: handle
                   )

          assert :ok = GRPC.Stub.cancel(handle)
        end)
      end

      test "a server-streaming call cancelled while the stream is open ends with CANCELED",
           %{connect_opts: connect_opts} do
        run_server(RouteServer, fn port ->
          {:ok, channel} = GRPC.Stub.connect("localhost:#{port}", connect_opts)
          handle = GRPC.Stub.new_cancel_handle()

          {:ok, replies} =
            Routeguide.RouteGuide.Stub.list_features(channel, %Routeguide.Rectangle{},
              cancel: handle
            )

          assert_receive {:handler, handler}, @reset_wait
          ref = Process.monitor(handler)

          assert [{:ok, %Routeguide.Feature{name: "one"}}] = Enum.take(replies, 1)

          assert :ok = GRPC.Stub.cancel(handle)

          assert {:error, %RPCError{status: @canceled}} = replies |> Enum.to_list() |> List.last()
          assert_receive {:DOWN, ^ref, :process, ^handler, _}, @reset_wait
        end)
      end

      test "halting the replies of a server-streaming call resets the stream",
           %{connect_opts: connect_opts} do
        run_server(RouteServer, fn port ->
          {:ok, channel} = GRPC.Stub.connect("localhost:#{port}", connect_opts)

          {:ok, replies} =
            Routeguide.RouteGuide.Stub.list_features(channel, %Routeguide.Rectangle{})

          assert_receive {:handler, handler}, @reset_wait
          ref = Process.monitor(handler)

          assert [{:ok, %Routeguide.Feature{name: "one"}}] = Enum.take(replies, 1)

          assert_receive {:DOWN, ^ref, :process, ^handler, _}, @reset_wait
        end)
      end
    end
  end
end
