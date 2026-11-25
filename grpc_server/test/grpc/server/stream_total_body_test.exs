defmodule GRPC.Server.StreamTotalBodyTest do
  # The default `:max_body_size` bounds a request body that arrives whole. A request
  # stream is bounded per message by `:max_message_length`, so a long-lived stream of
  # small messages is not cut off when its total passes the default.
  use ExUnit.Case, async: false

  @four_mib 4 * 1024 * 1024

  defmodule RouteServer do
    use GRPC.Server, service: Routeguide.RouteGuide.Service

    def record_route(req_enum, _stream) do
      %Routeguide.RouteSummary{point_count: Enum.count(req_enum)}
    end

    def route_chat(req_enum, stream) do
      Enum.each(req_enum, &GRPC.Server.send_reply(stream, &1))
    end
  end

  # An unknown field is skipped by the decoder, so this is a valid message of either type.
  defp frame do
    padding = String.duplicate("x", 1_000)
    length = IO.iodata_to_binary(Protobuf.Wire.Varint.encode(byte_size(padding)))
    message = <<122>> <> length <> padding
    <<0, byte_size(message)::32, message::binary>>
  end

  defp run_server(opts, func) do
    {:ok, _pid, port} =
      start_supervised(%{
        id: {GRPC.Server, System.unique_integer([:positive])},
        start: {GRPC.Server, :start, [RouteServer, 0, opts]},
        type: :worker,
        restart: :permanent,
        shutdown: 500
      })

    try do
      func.(port)
    after
      GRPC.Server.stop(RouteServer)
    end
  end

  # Sends `count` messages as a client-streaming call and returns the grpc-status.
  defp record_route_status(port, count) do
    {:ok, conn} = :gun.open(~c"localhost", port, %{protocols: [:http2]})
    {:ok, :http2} = :gun.await_up(conn, 5_000)

    ref =
      :gun.post(conn, "/routeguide.RouteGuide/RecordRoute", [
        {"content-type", "application/grpc+proto"},
        {"te", "trailers"}
      ])

    frame = frame()
    for _ <- 1..(count - 1), do: :gun.data(conn, ref, :nofin, frame)
    :gun.data(conn, ref, :fin, frame)

    status = await_status(conn, ref)
    :gun.close(conn)
    status
  end

  defp await_status(conn, ref) do
    case :gun.await(conn, ref, 20_000) do
      {:response, :fin, _status, headers} -> status_of(headers)
      {:response, :nofin, _status, headers} -> status_of(headers) || await_status(conn, ref)
      {:data, _fin, _data} -> await_status(conn, ref)
      {:trailers, trailers} -> status_of(trailers)
      {:error, reason} -> flunk("gun error: #{inspect(reason)}")
    end
  end

  defp status_of(headers) do
    case List.keyfind(headers, "grpc-status", 0) do
      {_, status} -> status
      nil -> nil
    end
  end

  test "a client stream of small messages totalling over 4 MiB is accepted by default" do
    count = div(@four_mib, byte_size(frame())) * 2

    run_server([], fn port ->
      assert "0" = record_route_status(port, count)
    end)
  end

  test "an explicit :max_body_size still caps the total of a client stream" do
    count = div(@four_mib, byte_size(frame())) * 2

    ExUnit.CaptureLog.capture_log(fn ->
      run_server([max_body_size: @four_mib], fn port ->
        assert "8" = record_route_status(port, count)
      end)
    end)
  end
end
