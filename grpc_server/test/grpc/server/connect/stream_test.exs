defmodule GRPC.Server.Connect.StreamTest do
  use GRPC.Integration.TestCase, async: false

  alias GRPC.Test.ConnectClient

  defmodule RouteServer do
    use GRPC.Server, service: Routeguide.RouteGuide.Service, compressors: [GRPC.Compressor.Gzip]

    def list_features(%{lo: %{latitude: 99}}, _stream) do
      raise GRPC.RPCError, status: :not_found, message: "nothing here"
    end

    def list_features(%{lo: %{latitude: 98}}, stream) do
      GRPC.Server.send_reply(stream, %Routeguide.Feature{name: "first"})
      raise GRPC.RPCError, status: :aborted, message: "stopped"
    end

    def list_features(_rect, stream) do
      GRPC.Server.set_trailers(stream, %{"x-custom-trailer" => "from-server-trailer"})
      GRPC.Server.send_reply(stream, %Routeguide.Feature{name: "one"})
      GRPC.Server.send_reply(stream, %Routeguide.Feature{name: "two"})
    end

    def record_route(req_enum, _stream) do
      points = Enum.to_list(req_enum)
      %Routeguide.RouteSummary{point_count: length(points)}
    end

    def route_chat(req_enum, stream) do
      Enum.each(req_enum, fn note ->
        GRPC.Server.send_reply(stream, %Routeguide.RouteNote{message: "echo " <> note.message})
      end)
    end
  end

  defp envelope(flag, payload), do: <<flag, byte_size(payload)::32, payload::binary>>

  defp parse(<<>>), do: []

  defp parse(<<flag, length::32, payload::binary-size(length), rest::binary>>),
    do: [{flag, payload} | parse(rest)]

  defp call(port, version, method, content_type, body, extra \\ []) do
    ConnectClient.request(
      port,
      version,
      "POST",
      "/routeguide.RouteGuide/" <> method,
      [{"content-type", content_type}, {"connect-protocol-version", "1"} | extra],
      body
    )
  end

  defp proto(message), do: Protobuf.encode(message)

  for version <- [:http, :http2] do
    describe "streams over #{version}" do
      test "a server stream sends messages then the end of the stream" do
        run_server(RouteServer, fn port ->
          body = envelope(0, proto(%Routeguide.Rectangle{}))

          response =
            call(port, unquote(version), "ListFeatures", "application/connect+proto", body)

          assert response.status == 200
          assert ConnectClient.header(response, "content-type") == "application/connect+proto"

          assert [{0, one}, {0, two}, {2, end_stream}] = parse(response.body)
          assert Routeguide.Feature.decode(one).name == "one"
          assert Routeguide.Feature.decode(two).name == "two"

          assert %{"metadata" => %{"x-custom-trailer" => ["from-server-trailer"]}} =
                   decoded = Jason.decode!(end_stream)

          refute Map.has_key?(decoded, "error")
        end)
      end

      test "a server stream with json messages" do
        run_server(RouteServer, fn port ->
          body = envelope(0, "{}")

          response =
            call(port, unquote(version), "ListFeatures", "application/connect+json", body)

          assert response.status == 200
          assert ConnectClient.header(response, "content-type") == "application/connect+json"
          assert [{0, one}, {0, _two}, {2, _end}] = parse(response.body)
          assert %{"name" => "one"} = Jason.decode!(one)
        end)
      end

      test "a client stream sends one message" do
        run_server(RouteServer, fn port ->
          point = proto(%Routeguide.Point{latitude: 1})
          body = envelope(0, point) <> envelope(0, point) <> envelope(0, point)

          response =
            call(port, unquote(version), "RecordRoute", "application/connect+proto", body)

          assert response.status == 200
          assert [{0, summary}, {2, end_stream}] = parse(response.body)
          assert Routeguide.RouteSummary.decode(summary).point_count == 3
          refute Map.has_key?(Jason.decode!(end_stream), "error")
        end)
      end

      test "a bidi stream answers every message" do
        run_server(RouteServer, fn port ->
          body =
            for m <- ["a", "b"], into: "" do
              envelope(0, proto(%Routeguide.RouteNote{message: m}))
            end

          response = call(port, unquote(version), "RouteChat", "application/connect+proto", body)

          assert [{0, a}, {0, b}, {2, _end}] = parse(response.body)
          assert Routeguide.RouteNote.decode(a).message == "echo a"
          assert Routeguide.RouteNote.decode(b).message == "echo b"
        end)
      end

      test "an error before any message is in the end of the stream, with status 200" do
        run_server(RouteServer, fn port ->
          body = envelope(0, proto(%Routeguide.Rectangle{lo: %Routeguide.Point{latitude: 99}}))

          response =
            call(port, unquote(version), "ListFeatures", "application/connect+proto", body)

          assert response.status == 200
          assert [{2, end_stream}] = parse(response.body)

          assert %{"error" => %{"code" => "not_found", "message" => "nothing here"}} =
                   Jason.decode!(end_stream)
        end)
      end

      test "an error after a message is in the end of the stream" do
        run_server(RouteServer, fn port ->
          body = envelope(0, proto(%Routeguide.Rectangle{lo: %Routeguide.Point{latitude: 98}}))

          response =
            call(port, unquote(version), "ListFeatures", "application/connect+proto", body)

          assert response.status == 200
          assert [{0, first}, {2, end_stream}] = parse(response.body)
          assert Routeguide.Feature.decode(first).name == "first"
          assert %{"error" => %{"code" => "aborted"}} = Jason.decode!(end_stream)
        end)
      end

      test "a message that does not decode is an invalid_argument" do
        run_server(RouteServer, fn port ->
          response =
            call(
              port,
              unquote(version),
              "ListFeatures",
              "application/connect+json",
              envelope(0, "not json")
            )

          assert [{2, end_stream}] = parse(response.body)
          assert %{"error" => %{"code" => "invalid_argument"}} = Jason.decode!(end_stream)
        end)
      end

      test "compressed messages in both directions" do
        run_server(RouteServer, fn port ->
          body = envelope(1, :zlib.gzip(proto(%Routeguide.Rectangle{})))

          response =
            call(
              port,
              unquote(version),
              "ListFeatures",
              "application/connect+proto",
              body,
              [{"connect-content-encoding", "gzip"}, {"connect-accept-encoding", "gzip"}]
            )

          assert ConnectClient.header(response, "connect-content-encoding") == "gzip"
          assert [{1, one}, {1, _two}, {2, _end}] = parse(response.body)
          assert Routeguide.Feature.decode(:zlib.gunzip(one)).name == "one"
        end)
      end
    end
  end

  test "a bidi stream answers while the request is still open over HTTP/2" do
    run_server(RouteServer, fn port ->
      {:ok, conn} = :gun.open(~c"localhost", port, %{protocols: [:http2], retry: 0})
      {:ok, :http2} = :gun.await_up(conn, 5_000)

      ref =
        :gun.post(conn, "/routeguide.RouteGuide/RouteChat", [
          {"content-type", "application/connect+proto"},
          {"connect-protocol-version", "1"}
        ])

      :gun.data(conn, ref, :nofin, envelope(0, proto(%Routeguide.RouteNote{message: "a"})))

      assert {:response, :nofin, 200, _headers} = :gun.await(conn, ref, 5_000)
      assert {:data, :nofin, first} = :gun.await(conn, ref, 5_000)
      assert [{0, a}] = parse(first)
      assert Routeguide.RouteNote.decode(a).message == "echo a"

      :gun.data(conn, ref, :fin, envelope(0, proto(%Routeguide.RouteNote{message: "b"})))

      rest = collect(conn, ref, "")
      assert [{0, b}, {2, _end}] = parse(rest)
      assert Routeguide.RouteNote.decode(b).message == "echo b"
      :gun.close(conn)
    end)
  end

  defp collect(conn, ref, acc) do
    case :gun.await(conn, ref, 5_000) do
      {:data, :nofin, data} -> collect(conn, ref, acc <> data)
      {:data, :fin, data} -> acc <> data
      {:trailers, _} -> acc
    end
  end
end
