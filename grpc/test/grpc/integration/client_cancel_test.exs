defmodule GRPC.Integration.ClientCancelTest do
  use GRPC.Integration.TestCase, async: true

  alias GRPC.Client.Adapters.{Gun, Mint}

  @canceled GRPC.Status.cancelled()

  defmodule EchoServer do
    use GRPC.Server, service: Routeguide.RouteGuide.Service

    def route_chat(req_enum, stream) do
      Enum.each(req_enum, fn note -> GRPC.Server.send_reply(stream, note) end)
    end
  end

  for adapter <- [Gun, Mint] do
    describe "with the #{inspect(adapter)} adapter" do
      @describetag adapter: adapter

      test "a reply stream read after the call is cancelled ends with CANCELED",
           %{adapter: adapter} do
        run_server(EchoServer, fn port ->
          {:ok, channel} = GRPC.Stub.connect("localhost:#{port}", adapter: adapter)

          stream = Routeguide.RouteGuide.Stub.route_chat(channel)
          stream = GRPC.Stub.send_request(stream, %Routeguide.RouteNote{message: "a"})
          {:ok, replies} = GRPC.Stub.recv(stream)

          GRPC.Stub.cancel(stream)

          assert {:error, %GRPC.RPCError{status: @canceled}} =
                   replies |> Enum.to_list() |> List.last()
        end)
      end
    end
  end
end
