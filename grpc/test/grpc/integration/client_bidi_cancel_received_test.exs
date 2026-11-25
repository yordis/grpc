defmodule GRPC.Integration.ClientBidiCancelReceivedTest do
  # Cancels a bidi stream with `GRPC.Stub.cancel/1` after the whole response arrived, but
  # before the caller read it: the caller gets CANCELLED next, and nothing of what was left.
  use GRPC.Integration.TestCase, async: false

  alias GRPC.Client.Adapters.{Gun, Mint}
  alias GRPC.RPCError

  @canceled GRPC.Status.cancelled()

  defmodule ChatServer do
    use GRPC.Server, service: Routeguide.RouteGuide.Service, connect: true

    def route_chat(req_enum, stream) do
      Enum.each(req_enum, fn note ->
        GRPC.Server.send_reply(stream, %{note | message: "Reply: #{note.message}"})
      end)

      send(Application.fetch_env!(:grpc, :cancel_test_pid), :sent)
    end
  end

  setup do
    Application.put_env(:grpc, :cancel_test_pid, self())
    on_exit(fn -> Application.delete_env(:grpc, :cancel_test_pid) end)
  end

  defp note(n), do: %Routeguide.RouteNote{message: "Message #{n}"}

  for adapter <- [Gun, Mint], protocol <- [:grpc, :connect, :grpc_web] do
    test "#{inspect(adapter)} over #{protocol}: a bidi stream cancelled after it arrived ends with CANCELLED" do
      run_server(ChatServer, fn port ->
        {:ok, channel} =
          GRPC.Stub.connect("localhost:#{port}",
            adapter: unquote(adapter),
            protocol: unquote(protocol),
            adapter_opts: [protocols: [:http2]]
          )

        stream = Routeguide.RouteGuide.Stub.route_chat(channel)
        GRPC.Stub.send_request(stream, note(1))
        GRPC.Stub.send_request(stream, note(2))
        GRPC.Stub.send_request(stream, note(3), end_stream: true)

        assert {:ok, replies} = GRPC.Stub.recv(stream)
        assert [{:ok, %{message: "Reply: Message 1"}}] = Enum.take(replies, 1)

        # The rest of the response arrives before the cancel.
        assert_receive :sent, 1_000
        Process.sleep(100)
        GRPC.Stub.cancel(stream)

        assert [{:error, %RPCError{status: @canceled}}] = Enum.to_list(replies)
      end)
    end
  end
end
