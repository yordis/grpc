defmodule GRPC.Integration.ClientReceiveLimitTest do
  # The receive limit is set per channel and per call, without the application env.
  use GRPC.Integration.TestCase, async: true

  alias GRPC.Client.Adapters.{Gun, Mint}
  alias GRPC.RPCError

  @resource_exhausted GRPC.Status.resource_exhausted()
  @reply_size 600

  defmodule HelloServer do
    use GRPC.Server, service: Helloworld.Greeter.Service

    def say_hello(_req, _stream),
      do: %Helloworld.HelloReply{message: String.duplicate("x", 600)}
  end

  defmodule RouteServer do
    use GRPC.Server, service: Routeguide.RouteGuide.Service

    def list_features(_rect, stream) do
      GRPC.Server.send_reply(stream, %Routeguide.Feature{name: String.duplicate("x", 600)})
    end
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

      test "the limit of the channel bounds a unary reply", %{connect_opts: connect_opts} do
        run_server(HelloServer, fn port ->
          small = connect(port, connect_opts, max_receive_message_length: @reply_size - 1)
          exact = connect(port, connect_opts, max_receive_message_length: @reply_size + 20)

          assert {:error, %RPCError{status: @resource_exhausted, message: message}} =
                   say_hello(small, [])

          assert message =~ "Received message is too large"
          assert message =~ "the limit is #{@reply_size - 1} bytes"
          assert {:ok, %Helloworld.HelloReply{}} = say_hello(exact, [])
        end)
      end

      test "the limit of a call overrides the one of the channel", %{connect_opts: connect_opts} do
        run_server(HelloServer, fn port ->
          channel = connect(port, connect_opts, max_receive_message_length: 100)

          assert {:error, %RPCError{status: @resource_exhausted}} = say_hello(channel, [])

          assert {:ok, %Helloworld.HelloReply{}} =
                   say_hello(channel, max_receive_message_length: 10_000)

          assert {:error, %RPCError{status: @resource_exhausted}} =
                   say_hello(connect(port, connect_opts, []),
                     max_receive_message_length: @reply_size - 1
                   )
        end)
      end

      test "calls in parallel keep their own limits", %{connect_opts: connect_opts} do
        run_server(HelloServer, fn port ->
          channel = connect(port, connect_opts, [])

          results =
            1..20
            |> Task.async_stream(fn n ->
              limit = if rem(n, 2) == 0, do: 100, else: 10_000
              {limit, say_hello(channel, max_receive_message_length: limit)}
            end)
            |> Enum.map(fn {:ok, result} -> result end)

          for {limit, result} <- results do
            case limit do
              100 -> assert {:error, %RPCError{status: @resource_exhausted}} = result
              10_000 -> assert {:ok, %Helloworld.HelloReply{}} = result
            end
          end
        end)
      end

      test "the limit bounds a server-streaming reply", %{connect_opts: connect_opts} do
        run_server(RouteServer, fn port ->
          channel = connect(port, connect_opts, max_receive_message_length: 100)

          {:ok, replies} =
            Routeguide.RouteGuide.Stub.list_features(channel, %Routeguide.Rectangle{})

          assert {:error, %RPCError{status: @resource_exhausted}} =
                   replies |> Enum.to_list() |> List.last()

          {:ok, replies} =
            Routeguide.RouteGuide.Stub.list_features(channel, %Routeguide.Rectangle{},
              max_receive_message_length: 10_000
            )

          assert [{:ok, %Routeguide.Feature{}}] = Enum.to_list(replies)
        end)
      end
    end
  end

  defp connect(port, connect_opts, extra) do
    {:ok, channel} = GRPC.Stub.connect("localhost:#{port}", connect_opts ++ extra)
    channel
  end

  defp say_hello(channel, opts),
    do: Helloworld.Greeter.Stub.say_hello(channel, %Helloworld.HelloRequest{name: "x"}, opts)
end
