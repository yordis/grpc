defmodule GRPC.Integration.ClientStreamDeadlineTest do
  use ExUnit.Case, async: true

  alias GRPC.Client.Adapters.{Gun, Mint}
  alias GRPC.Integration.ScriptedH2Server

  @deadline_exceeded GRPC.Status.deadline_exceeded()

  # The server never answers: the call's own timeout has to end it.
  defp silent_server, do: ScriptedH2Server.start([{:sleep, 5_000}])

  defp first_error({:error, error}), do: error

  defp first_error({:ok, replies}) do
    Enum.find_value(replies, fn
      {:error, error} -> error
      _ -> nil
    end)
  end

  for adapter <- [Gun, Mint] do
    describe "with the #{inspect(adapter)} adapter" do
      @describetag adapter: adapter
      @describetag timeout: 4_000

      test "a server stream that never answers ends at its timeout", %{adapter: adapter} do
        channel = ScriptedH2Server.connect(silent_server(), adapter)

        result =
          Routeguide.RouteGuide.Stub.list_features(channel, %Routeguide.Rectangle{}, timeout: 300)

        assert %GRPC.RPCError{status: @deadline_exceeded} = first_error(result)
      end

      test "a client stream that never answers ends at its timeout", %{adapter: adapter} do
        channel = ScriptedH2Server.connect(silent_server(), adapter)

        stream = Routeguide.RouteGuide.Stub.record_route(channel, timeout: 300)
        stream = GRPC.Stub.send_request(stream, %Routeguide.Point{}, end_stream: true)

        assert {:error, %GRPC.RPCError{status: @deadline_exceeded}} = GRPC.Stub.recv(stream)
      end

      test "a bidirectional stream that never answers ends at its timeout", %{adapter: adapter} do
        channel = ScriptedH2Server.connect(silent_server(), adapter)

        stream = Routeguide.RouteGuide.Stub.route_chat(channel, timeout: 300)
        stream = GRPC.Stub.send_request(stream, %Routeguide.RouteNote{}, end_stream: true)

        assert %GRPC.RPCError{status: @deadline_exceeded} = first_error(GRPC.Stub.recv(stream))
      end
    end
  end
end
