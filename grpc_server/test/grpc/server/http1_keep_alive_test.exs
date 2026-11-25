defmodule GRPC.Server.Http1KeepAliveTest do
  use GRPC.Integration.TestCase, async: false

  # A client reuses an HTTP/1.1 connection after any reply, an error too. A server that
  # closes it after the reply makes the next request fail by chance ("server closed idle
  # connection"), so no reply may end the connection.

  defmodule HelloServer do
    use GRPC.Server, service: Helloworld.Greeter.Service

    def say_hello(%{name: "boom"}, _stream) do
      raise GRPC.RPCError, status: :unauthenticated, message: "no"
    end

    def say_hello(req, _stream), do: %Helloworld.HelloReply{message: "Hello, #{req.name}"}
  end

  defp frame(payload), do: <<0, byte_size(payload)::32, payload::binary>>

  defp json(name), do: ~s({"name":"#{name}"})

  defp proto(name), do: Protobuf.encode(%Helloworld.HelloRequest{name: name})

  @path "/helloworld.Greeter/SayHello"

  defp await_response(conn, ref) do
    case :gun.await(conn, ref, 5_000) do
      {:response, :fin, _status, _headers} -> :ok
      {:response, :nofin, _status, _headers} -> drain(conn, ref)
    end
  end

  defp drain(conn, ref) do
    case :gun.await(conn, ref, 5_000) do
      {:data, :nofin, _} -> drain(conn, ref)
      {:data, :fin, _} -> :ok
      {:trailers, _} -> :ok
    end
  end

  defp assert_kept_alive(port, content_type, headers, body, path \\ @path) do
    {:ok, conn} = :gun.open(~c"localhost", port, %{protocols: [:http], retry: 0})
    {:ok, :http} = :gun.await_up(conn, 5_000)

    ref = :gun.post(conn, path,[{"content-type", content_type} | headers], body)
    await_response(conn, ref)

    refute_receive {:gun_down, ^conn, _, _, _}, 300
    :gun.close(conn)
  end

  for {name, content_type, headers, body} <- [
        {"connect error", "application/json", [{"connect-protocol-version", "1"}],
         ~s({"name":"boom"})},
        {"connect not json", "application/json", [{"connect-protocol-version", "1"}], "not json"},
        {"connect unsupported type", "application/x-nope", [{"connect-protocol-version", "1"}],
         ""},
        {"grpc-web error", "application/grpc-web+proto", [],
         <<0, 12::32, Protobuf.encode(%Helloworld.HelloRequest{name: "boom"})::binary, 0::32>>},
        {"grpc-web unknown compression", "application/grpc-web+proto",
         [{"grpc-encoding", "nope"}], <<0, 0::32>>},
        {"grpc unknown compression", "application/grpc+proto", [{"grpc-encoding", "nope"}],
         <<0, 0::32>>}
      ] do
    test "the connection stays open after: #{name}" do
      run_server(HelloServer, fn port ->
        assert_kept_alive(port, unquote(content_type), unquote(headers), unquote(body))
      end)
    end
  end

  defmodule RouteServer do
    use GRPC.Server, service: Routeguide.RouteGuide.Service

    def list_features(%{lo: %{latitude: 99}}, _stream) do
      raise GRPC.RPCError, status: :resource_exhausted, message: "no"
    end

    def list_features(%{lo: %{latitude: 98}}, stream) do
      GRPC.Server.send_reply(stream, %Routeguide.Feature{name: "first"})
      raise GRPC.RPCError, status: :unknown, message: "after a message"
    end

    def list_features(_rect, stream) do
      GRPC.Server.send_reply(stream, %Routeguide.Feature{name: "one"})
    end
  end

  for {name, latitude} <- [{"before a message", 99}, {"after a message", 98}, {"none", 1}] do
    test "the connection stays open after a Connect stream that fails: #{name}" do
      run_server(RouteServer, fn port ->
        rectangle = Protobuf.encode(%Routeguide.Rectangle{lo: %Routeguide.Point{latitude: unquote(latitude)}})

        assert_kept_alive(
          port,
          "application/connect+proto",
          [{"connect-protocol-version", "1"}],
          frame(rectangle),
          "/routeguide.RouteGuide/ListFeatures"
        )
      end)
    end

    test "the connection stays open after a gRPC-Web stream that fails: #{name}" do
      run_server(RouteServer, fn port ->
        rectangle = Protobuf.encode(%Routeguide.Rectangle{lo: %Routeguide.Point{latitude: unquote(latitude)}})

        assert_kept_alive(
          port,
          "application/grpc-web+proto",
          [],
          frame(rectangle),
          "/routeguide.RouteGuide/ListFeatures"
        )
      end)
    end
  end

  # A client that streams its request body (chunked, no content-length), as the Go HTTP
  # client does for every streaming call, may not have sent the last chunk when the reply
  # comes. Cowboy drops a connection whose request body is unfinished and of unknown
  # length, so the server reads what is left of it before it ends the request.
  defp assert_kept_alive_while_streaming(
         port,
         content_type,
         headers,
         first_chunk,
         path \\ @path,
         second_chunk \\ "",
         next_path \\ nil
       ) do
    {:ok, socket} = :gen_tcp.connect(~c"localhost", port, [:binary, active: false])

    request_headers =
      Enum.map_join([{"content-type", content_type} | headers], fn {k, v} -> "#{k}: #{v}\r\n" end)

    :ok =
      :gen_tcp.send(
        socket,
        "POST #{path} HTTP/1.1\r\nhost: localhost\r\ntransfer-encoding: chunked\r\n" <>
          request_headers <>
          "\r\n#{Integer.to_string(byte_size(first_chunk), 16)}\r\n#{first_chunk}\r\n"
      )

    # The reply is in before the last chunk of the request is sent.
    assert {:ok, "HTTP/1.1 " <> _} = :gen_tcp.recv(socket, 0, 5_000)
    if second_chunk != "" do
      Process.sleep(100)

      :ok =
        :gen_tcp.send(
          socket,
          "#{Integer.to_string(byte_size(second_chunk), 16)}\r\n#{second_chunk}\r\n"
        )
    end

    :ok = :gen_tcp.send(socket, "0\r\n\r\n")
    Process.sleep(300)

    :ok =
      :gen_tcp.send(
        socket,
        "POST #{next_path || path} HTTP/1.1\r\nhost: localhost\r\ncontent-type: application/json\r\n" <>
          "connect-protocol-version: 1\r\ncontent-length: 15\r\n\r\n{\"name\":\"next\"}"
      )

    # The second request is answered on the same socket.
    assert {:ok, data} = recv_until_second(socket, "")
    assert data =~ "Hello, next"
    :gen_tcp.close(socket)
  end

  defp recv_until_second(socket, acc) do
    case :gen_tcp.recv(socket, 0, 2_000) do
      {:ok, data} ->
        acc = acc <> data
        if acc =~ "Hello, next", do: {:ok, acc}, else: recv_until_second(socket, acc)

      {:error, reason} ->
        {:error, {reason, acc}}
    end
  end

  for {name, content_type, headers, body} <- [
        {"connect unsupported type", "application/x-nope", [{"connect-protocol-version", "1"}],
         "{"},
        {"grpc-web unknown compression", "application/grpc-web+proto",
         [{"grpc-encoding", "nope"}], <<0, 0::32>>},
        {"grpc unknown compression", "application/grpc+proto", [{"grpc-encoding", "nope"}],
         <<0, 0::32>>}
      ] do
    test "the connection stays open after: #{name}, with the request body still streaming" do
      run_server(HelloServer, fn port ->
        assert_kept_alive_while_streaming(
          port,
          unquote(content_type),
          unquote(headers),
          unquote(body)
        )
      end)
    end
  end

  # The router answers a path no service serves before any handler runs.
  for {name, content_type, headers} <- [
        {"connect", "application/json", [{"connect-protocol-version", "1"}]},
        {"grpc-web", "application/grpc-web+proto", []},
        {"grpc", "application/grpc+proto", []}
      ] do
    test "the connection stays open after an unknown method (#{name}), with the request body still streaming" do
      run_server(HelloServer, fn port ->
        assert_kept_alive_while_streaming(
          port,
          unquote(content_type),
          unquote(headers),
          "{}",
          "/unknown.Service/Method",
          "",
          @path
        )
      end)
    end
  end

  describe "a message over the limit" do
    setup do
      Application.put_env(:grpc, :max_message_length, 100)
      on_exit(fn -> Application.delete_env(:grpc, :max_message_length) end)
    end

    test "is answered, and the connection stays open when the body is small" do
      run_server(HelloServer, fn port ->
        assert_kept_alive(
          port,
          "application/json",
          [{"connect-protocol-version", "1"}],
          json(String.duplicate("a", 500))
        )
      end)
    end

    test "is answered, and the connection stays open when the body is large" do
      run_server(HelloServer, fn port ->
        assert_kept_alive(
          port,
          "application/grpc-web+proto",
          [],
          frame(proto(String.duplicate("a", 200_000)))
        )
      end)
    end

    test "is answered, and the connection stays open when the body is large and streamed" do
      run_server(HelloServer, fn port ->
        big = frame(proto(String.duplicate("a", 200_000)))

        assert_kept_alive_while_streaming(
          port,
          "application/grpc+proto",
          [],
          big,
          @path,
          big
        )
      end)
    end
  end
end
