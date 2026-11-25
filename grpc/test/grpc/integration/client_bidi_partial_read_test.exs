defmodule GRPC.Integration.ClientBidiPartialReadTest do
  # A caller reads the replies of a bidi stream in parts, between the requests it sends. The
  # state of the read lives until the stream ends, however the caller stops reading.
  use GRPC.Integration.TestCase, async: false

  alias GRPC.Client.Adapters.{Gun, Mint}

  defmodule ChatServer do
    use GRPC.Server, service: Routeguide.RouteGuide.Service, connect: true

    def route_chat(req_enum, stream) do
      Enum.each(req_enum, fn note ->
        GRPC.Server.send_reply(stream, %{note | message: "Reply: #{note.message}"})
      end)
    end
  end

  defp note(n), do: %Routeguide.RouteNote{message: "Message #{n}"}

  for adapter <- [Gun, Mint], protocol <- [:grpc, :connect, :grpc_web] do
    test "#{inspect(adapter)} over #{protocol} keeps reading a bidi stream after a part of it" do
      run_server(ChatServer, fn port ->
        {:ok, channel} =
          GRPC.Stub.connect("localhost:#{port}",
            adapter: unquote(adapter),
            protocol: unquote(protocol),
            adapter_opts: [protocols: [:http2]]
          )

        stream = Routeguide.RouteGuide.Stub.route_chat(channel)
        GRPC.Stub.send_request(stream, note(1))

        assert {:ok, replies} = GRPC.Stub.recv(stream)
        assert [{:ok, %{message: "Reply: Message 1"}}] = Enum.take(replies, 1)

        GRPC.Stub.send_request(stream, note(2), end_stream: true)

        assert [{:ok, %{message: "Reply: Message 2"}}] = Enum.to_list(replies)
      end)
    end
  end
end
