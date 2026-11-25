defmodule GRPC.Integration.ConnectClientStreamTest do
  use GRPC.Integration.TestCase, async: false

  alias GRPC.Client.Adapters.Mint

  defmodule FeatureServer do
    use GRPC.Server, service: Routeguide.RouteGuide.Service, compressors: [GRPC.Compressor.Gzip]
    alias GRPC.Server

    def list_features(%{lo: %{latitude: 13}}, _stream) do
      raise GRPC.RPCError, status: :not_found, message: "no features"
    end

    def list_features(rectangle, stream) do
      Server.set_headers(stream, %{"x-custom-header" => "from-server"})

      Enum.each([rectangle.lo, rectangle.hi], fn point ->
        Server.send_reply(stream, feature(point))
      end)

      Server.set_trailers(stream, %{"x-custom-trailer" => "from-server-trailer"})
    end

    def record_route(req_enum, _stream) do
      count = Enum.count(req_enum)

      %Routeguide.RouteSummary{point_count: count}
    end

    def route_chat(req_enum, stream) do
      Enum.each(req_enum, fn note ->
        Server.send_reply(stream, %{note | message: "Reply: #{note.message}"})
      end)
    end

    defp feature(point), do: %Routeguide.Feature{location: point, name: "#{point.latitude}"}
  end

  def connect(port, opts \\ []) do
    {:ok, channel} =
      GRPC.Stub.connect("localhost:#{port}", [adapter: Mint, protocol: :connect] ++ opts)

    channel
  end

  def note(i), do: %Routeguide.RouteNote{message: "Message #{i}"}

  for protocols <- [[:http2], [:http1]] do
    describe "a streaming Connect call over #{inspect(protocols)}" do
      @describetag protocols: protocols

      test "a server stream returns the messages, the headers and the trailers", %{
        protocols: protocols
      } do
        run_server(FeatureServer, fn port ->
          channel = connect(port, adapter_opts: [protocols: protocols])
          low = %Routeguide.Point{latitude: 1}
          high = %Routeguide.Point{latitude: 2}

          assert {:ok, stream} =
                   Routeguide.RouteGuide.Stub.list_features(
                     channel,
                     %Routeguide.Rectangle{lo: low, hi: high},
                     return_headers: true
                   )

          assert [
                   {:headers, %{"x-custom-header" => "from-server"}},
                   {:ok, %Routeguide.Feature{name: "1"}},
                   {:ok, %Routeguide.Feature{name: "2"}},
                   {:trailers, %{"x-custom-trailer" => "from-server-trailer"}}
                 ] = Enum.to_list(stream)
        end)
      end

      test "a server stream ends with the error of the server", %{protocols: protocols} do
        run_server(FeatureServer, fn port ->
          channel = connect(port, adapter_opts: [protocols: protocols])
          rect = %Routeguide.Rectangle{lo: %Routeguide.Point{latitude: 13}}

          assert {:ok, stream} = Routeguide.RouteGuide.Stub.list_features(channel, rect)

          assert [{:error, %GRPC.RPCError{status: 5, message: "no features"}}] =
                   Enum.to_list(stream)
        end)
      end

      test "a client stream returns the reply", %{protocols: protocols} do
        run_server(FeatureServer, fn port ->
          channel = connect(port, adapter_opts: [protocols: protocols])

          stream = Routeguide.RouteGuide.Stub.record_route(channel)
          GRPC.Stub.send_request(stream, %Routeguide.Point{})
          GRPC.Stub.send_request(stream, %Routeguide.Point{}, end_stream: true)

          assert {:ok, %Routeguide.RouteSummary{point_count: 2}} = GRPC.Stub.recv(stream)
        end)
      end

      test "a bidi stream sends all, then reads all", %{protocols: protocols} do
        run_server(FeatureServer, fn port ->
          channel = connect(port, adapter_opts: [protocols: protocols])

          stream = Routeguide.RouteGuide.Stub.route_chat(channel)
          GRPC.Stub.send_request(stream, note(1))
          GRPC.Stub.send_request(stream, note(2), end_stream: true)

          assert {:ok, replies} = GRPC.Stub.recv(stream)

          assert [{:ok, %{message: "Reply: Message 1"}}, {:ok, %{message: "Reply: Message 2"}}] =
                   Enum.to_list(replies)
        end)
      end

      test "a stream compresses its messages", %{protocols: protocols} do
        run_server(FeatureServer, fn port ->
          channel = connect(port, adapter_opts: [protocols: protocols])

          stream = Routeguide.RouteGuide.Stub.route_chat(channel, compressor: GRPC.Compressor.Gzip)
          GRPC.Stub.send_request(stream, note(1), end_stream: true)

          assert {:ok, replies} = GRPC.Stub.recv(stream)
          assert [{:ok, %{message: "Reply: Message 1"}}] = Enum.to_list(replies)
        end)
      end
    end
  end

  test "a bidi stream over HTTP/2 reads a reply before the request ends" do
    run_server(FeatureServer, fn port ->
      channel = connect(port, adapter_opts: [protocols: [:http2]])

      stream = Routeguide.RouteGuide.Stub.route_chat(channel)
      GRPC.Stub.send_request(stream, note(1))

      assert {:ok, replies} = GRPC.Stub.recv(stream)
      assert [{:ok, %{message: "Reply: Message 1"}}] = Enum.take(replies, 1)

      GRPC.Stub.send_request(stream, note(2), end_stream: true)
    end)
  end
end
