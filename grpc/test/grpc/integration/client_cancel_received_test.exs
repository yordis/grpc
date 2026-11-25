defmodule GRPC.Integration.ClientCancelReceivedTest do
  # Cancels a server-streaming call after the whole response arrived, but before the
  # caller read it: the caller gets CANCELLED next, and nothing of what was left.
  use GRPC.Integration.TestCase, async: false

  alias GRPC.Client.Adapters.{Gun, Mint}
  alias GRPC.RPCError

  @canceled GRPC.Status.cancelled()

  defmodule RouteServer do
    use GRPC.Server, service: Routeguide.RouteGuide.Service, connect: true

    def list_features(_rect, stream) do
      for name <- ["one", "two", "three"] do
        GRPC.Server.send_reply(stream, %Routeguide.Feature{name: name})
      end

      send(Application.fetch_env!(:grpc, :cancel_test_pid), :sent)
    end
  end

  setup do
    Application.put_env(:grpc, :cancel_test_pid, self())
    on_exit(fn -> Application.delete_env(:grpc, :cancel_test_pid) end)
  end

  setups =
    for adapter <- [Gun, Mint],
        {protocol, versions} <- [
          grpc: [:http2],
          connect: [:http1, :http2],
          grpc_web: [:http1, :http2]
        ],
        version <- versions do
      {"#{inspect(adapter)} with #{protocol} over #{version}",
       [adapter: adapter, protocol: protocol, adapter_opts: [protocols: [version]]]}
    end

  for {name, connect_opts} <- setups do
    describe name do
      @describetag connect_opts: connect_opts

      test "a server stream cancelled after it arrived ends with CANCELLED and no more replies",
           %{connect_opts: connect_opts} do
        run_server(RouteServer, fn port ->
          {:ok, channel} = GRPC.Stub.connect("localhost:#{port}", connect_opts)
          handle = GRPC.Stub.new_cancel_handle()

          {:ok, replies} =
            Routeguide.RouteGuide.Stub.list_features(channel, %Routeguide.Rectangle{},
              cancel: handle
            )

          items =
            Enum.map(replies, fn
              {:ok, %Routeguide.Feature{name: "one"}} = item ->
                # The rest of the response arrives before the cancel.
                assert_receive :sent, 1_000
                Process.sleep(100)
                GRPC.Stub.cancel(handle)
                item

              item ->
                item
            end)

          assert [{:ok, %Routeguide.Feature{name: "one"}}, {:error, %RPCError{status: @canceled}}] =
                   items
        end)
      end
    end
  end
end
