defmodule GRPC.Server.GrpcWebContentTypeTest do
  use ExUnit.Case, async: false

  defmodule HelloServer do
    use GRPC.Server, service: Helloworld.Greeter.Service

    def say_hello(%{name: "fail"}, _stream) do
      raise GRPC.RPCError, status: :invalid_argument, message: "bad name"
    end

    def say_hello(req, _stream), do: %Helloworld.HelloReply{message: "Hello, #{req.name}"}
  end

  setup do
    {:ok, _pid, port} =
      start_supervised(%{
        id: {GRPC.Server, System.unique_integer([:positive])},
        start: {GRPC.Server, :start, [HelloServer, 0, []]},
        type: :worker,
        restart: :permanent,
        shutdown: 500
      })

    on_exit(fn -> GRPC.Server.stop(HelloServer) end)
    %{port: port}
  end

  defp post(port, content_type, name) do
    proto = Protobuf.encode(%Helloworld.HelloRequest{name: name})
    body = <<0::8, byte_size(proto)::32, proto::binary>>

    {:ok, conn} = :gun.open(~c"localhost", port, %{protocols: [:http]})
    {:ok, :http} = :gun.await_up(conn, 5_000)

    ref =
      :gun.post(conn, "/helloworld.Greeter/SayHello", [{"content-type", content_type}], body)

    {:response, _fin, status, headers} = :gun.await(conn, ref, 3_000)
    {:ok, resp_body} = :gun.await_body(conn, ref, 3_000)
    :gun.close(conn)
    {status, Map.new(headers), resp_body}
  end

  test "a gRPC-web+proto response echoes the grpc-web+proto content-type", %{port: port} do
    {200, headers, _body} = post(port, "application/grpc-web+proto", "web")
    assert headers["content-type"] == "application/grpc-web+proto"
  end

  test "a gRPC-web error is a grpc-web response with the status in the body trailer frame",
       %{port: port} do
    {200, headers, body} = post(port, "application/grpc-web+proto", "fail")
    assert headers["content-type"] == "application/grpc-web+proto"
    refute Map.has_key?(headers, "grpc-status")
    assert <<128, _len::32, trailers::binary>> = body
    assert trailers =~ "grpc-status: 3"
  end
end
