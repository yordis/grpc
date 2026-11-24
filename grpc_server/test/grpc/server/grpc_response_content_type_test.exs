defmodule GRPC.Server.GrpcResponseContentTypeTest do
  use GRPC.Integration.TestCase, async: false

  alias GRPC.Test.ConnectClient

  defmodule HelloServer do
    use GRPC.Server, service: Helloworld.Greeter.Service

    def say_hello(req, _stream), do: %Helloworld.HelloReply{message: "Hello, #{req.name}"}
  end

  defp call(port, content_type, payload) do
    ConnectClient.request(
      port,
      :http2,
      "POST",
      "/helloworld.Greeter/SayHello",
      [{"content-type", content_type}, {"te", "trailers"}],
      <<0, byte_size(payload)::32, payload::binary>>
    )
  end

  test "a gRPC call with JSON is answered with application/grpc+json" do
    run_server(HelloServer, fn port ->
      response = call(port, "application/grpc+json", ~s({"name":"json"}))

      assert ConnectClient.header(response, "content-type") == "application/grpc+json"
    end)
  end

  test "a gRPC call with proto is answered with application/grpc+proto" do
    run_server(HelloServer, fn port ->
      response =
        call(port, "application/grpc+proto", Protobuf.encode(%Helloworld.HelloRequest{name: "p"}))

      assert ConnectClient.header(response, "content-type") == "application/grpc+proto"
    end)
  end

  test "a gRPC-Web call with JSON is answered with application/grpc-web+json" do
    run_server(HelloServer, fn port ->
      response = call(port, "application/grpc-web+json", ~s({"name":"json"}))

      assert ConnectClient.header(response, "content-type") == "application/grpc-web+json"
    end)
  end
end
