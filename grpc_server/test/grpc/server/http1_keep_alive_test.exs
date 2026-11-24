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

  defp assert_kept_alive(port, content_type, headers, body) do
    {:ok, conn} = :gun.open(~c"localhost", port, %{protocols: [:http], retry: 0})
    {:ok, :http} = :gun.await_up(conn, 5_000)

    ref = :gun.post(conn, @path, [{"content-type", content_type} | headers], body)
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
  end
end
