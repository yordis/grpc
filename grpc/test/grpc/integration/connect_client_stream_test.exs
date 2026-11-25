defmodule GRPC.Integration.ConnectClientStreamTest do
  use GRPC.Integration.TestCase, async: false

  alias GRPC.Client.Adapters.Gun
  alias GRPC.Client.Adapters.Mint

  defmodule FeatureServer do
    use GRPC.Server,
      service: Routeguide.RouteGuide.Service,
      connect: true,
      compressors: [GRPC.Compressor.Gzip]

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
      Enum.each(req_enum, fn
        %{message: "fail"} ->
          raise GRPC.RPCError, status: :not_found, message: "no chat"

        note ->
          Server.send_reply(stream, %{note | message: "Reply: #{note.message}"})
      end)
    end

    defp feature(point), do: %Routeguide.Feature{location: point, name: "#{point.latitude}"}
  end

  def connect(port, adapter, opts) do
    {:ok, channel} =
      GRPC.Stub.connect("localhost:#{port}", [adapter: adapter, protocol: :connect] ++ opts)

    channel
  end

  def note(i), do: %Routeguide.RouteNote{message: "Message #{i}"}

  for adapter <- [Mint, Gun], protocols <- [[:http2], [:http1]] do
    describe "a streaming Connect call with #{inspect(adapter)} over #{inspect(protocols)}" do
      @describetag protocols: protocols, adapter: adapter

      test "a server stream returns the messages, the headers and the trailers", %{
        protocols: protocols,
        adapter: adapter
      } do
        run_server(FeatureServer, fn port ->
          channel = connect(port, adapter, adapter_opts: [protocols: protocols])
          low = %Routeguide.Point{latitude: 1}
          high = %Routeguide.Point{latitude: 2}

          assert {:ok, stream, %{headers: %{"x-custom-header" => "from-server"}}} =
                   Routeguide.RouteGuide.Stub.list_features(
                     channel,
                     %Routeguide.Rectangle{lo: low, hi: high},
                     return_headers: true
                   )

          assert [
                   {:ok, %Routeguide.Feature{name: "1"}},
                   {:ok, %Routeguide.Feature{name: "2"}},
                   {:trailers, %{"x-custom-trailer" => "from-server-trailer"}}
                 ] = Enum.to_list(stream)
        end)
      end

      test "a server stream ends with the error of the server", %{
        protocols: protocols,
        adapter: adapter
      } do
        run_server(FeatureServer, fn port ->
          channel = connect(port, adapter, adapter_opts: [protocols: protocols])
          rect = %Routeguide.Rectangle{lo: %Routeguide.Point{latitude: 13}}

          assert {:ok, stream} = Routeguide.RouteGuide.Stub.list_features(channel, rect)

          assert [{:error, %GRPC.RPCError{status: 5, message: "no features"}}] =
                   Enum.to_list(stream)
        end)
      end

      test "a client stream returns the reply", %{protocols: protocols, adapter: adapter} do
        run_server(FeatureServer, fn port ->
          channel = connect(port, adapter, adapter_opts: [protocols: protocols])

          stream = Routeguide.RouteGuide.Stub.record_route(channel)
          GRPC.Stub.send_request(stream, %Routeguide.Point{})
          GRPC.Stub.send_request(stream, %Routeguide.Point{}, end_stream: true)

          assert {:ok, %Routeguide.RouteSummary{point_count: 2}} = GRPC.Stub.recv(stream)
        end)
      end

      test "a bidi stream sends all, then reads all", %{protocols: protocols, adapter: adapter} do
        run_server(FeatureServer, fn port ->
          channel = connect(port, adapter, adapter_opts: [protocols: protocols])

          stream = Routeguide.RouteGuide.Stub.route_chat(channel)
          GRPC.Stub.send_request(stream, note(1))
          GRPC.Stub.send_request(stream, note(2), end_stream: true)

          assert {:ok, replies} = GRPC.Stub.recv(stream)

          assert [{:ok, %{message: "Reply: Message 1"}}, {:ok, %{message: "Reply: Message 2"}}] =
                   Enum.to_list(replies)
        end)
      end

      test "a stream compresses its messages", %{protocols: protocols, adapter: adapter} do
        run_server(FeatureServer, fn port ->
          channel = connect(port, adapter, adapter_opts: [protocols: protocols])

          stream =
            Routeguide.RouteGuide.Stub.route_chat(channel, compressor: GRPC.Compressor.Gzip)

          GRPC.Stub.send_request(stream, note(1), end_stream: true)

          assert {:ok, replies} = GRPC.Stub.recv(stream)
          assert [{:ok, %{message: "Reply: Message 1"}}] = Enum.to_list(replies)
        end)
      end
    end
  end

  for adapter <- [Mint, Gun], protocols <- [[:http2], [:http1]] do
    test "a client stream canceled before it is closed ends with canceled with #{inspect(adapter)} over #{inspect(protocols)}" do
      run_server(FeatureServer, fn port ->
        channel = connect(port, unquote(adapter), adapter_opts: [protocols: unquote(protocols)])

        stream = Routeguide.RouteGuide.Stub.record_route(channel)
        stream = GRPC.Stub.send_request(stream, %Routeguide.Point{})
        stream = GRPC.Stub.cancel(stream)
        stream = GRPC.Stub.end_stream(stream)

        assert {:error, %GRPC.RPCError{status: 1}} = GRPC.Stub.recv(stream, timeout: 2000)
      end)
    end
  end

  for adapter <- [Mint, Gun] do
    test "a bidi stream over HTTP/2 reads a reply before the request ends with #{inspect(adapter)}" do
      run_server(FeatureServer, fn port ->
        channel = connect(port, unquote(adapter), adapter_opts: [protocols: [:http2]])

        stream = Routeguide.RouteGuide.Stub.route_chat(channel)
        GRPC.Stub.send_request(stream, note(1))

        assert {:ok, replies} = GRPC.Stub.recv(stream)
        assert [{:ok, %{message: "Reply: Message 1"}}] = Enum.take(replies, 1)

        GRPC.Stub.send_request(stream, note(2), end_stream: true)
      end)
    end

    test "a bidi stream the server ends with an error before any reply, read in steps with #{inspect(adapter)}" do
      run_server(FeatureServer, fn port ->
        channel = connect(port, unquote(adapter), adapter_opts: [protocols: [:http2]])

        stream = Routeguide.RouteGuide.Stub.route_chat(channel, return_headers: true)
        GRPC.Stub.send_request(stream, %Routeguide.RouteNote{message: "fail"})

        assert {:ok, replies, %{headers: _}} = GRPC.Stub.recv(stream, return_headers: true)
        assert [{:trailers, _}] = Enum.take(replies, 1)
        assert [{:error, %GRPC.RPCError{status: 5}}] = Enum.take(replies, 1)
      end)
    end

    test "the replies of a bidi stream are read in steps with #{inspect(adapter)}" do
      run_server(FeatureServer, fn port ->
        channel = connect(port, unquote(adapter), adapter_opts: [protocols: [:http2]])

        stream = Routeguide.RouteGuide.Stub.route_chat(channel)
        GRPC.Stub.send_request(stream, note(1))

        assert {:ok, replies} = GRPC.Stub.recv(stream)
        assert [{:ok, %{message: "Reply: Message 1"}}] = Enum.take(replies, 1)

        GRPC.Stub.send_request(stream, note(2), end_stream: true)

        assert [{:ok, %{message: "Reply: Message 2"}}] = Enum.take(replies, 1)
        assert [] = Enum.to_list(replies)
      end)
    end
  end
end
