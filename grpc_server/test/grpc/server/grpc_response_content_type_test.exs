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

  describe "an error before the call starts" do
    for content_type <- ["application/grpc", "application/grpc-web", "application/grpc+proto"] do
      test "a compression the server lacks is unimplemented, with #{content_type}" do
        run_server(HelloServer, fn port ->
          response =
            ConnectClient.request(
              port,
              :http2,
              "POST",
              "/helloworld.Greeter/SayHello",
              [{"content-type", unquote(content_type)}, {"grpc-encoding", "unexpected"}],
              <<0, 0::32>>
            )

          assert ConnectClient.header(response, "content-type") == unquote(content_type)
          assert status(response) == "12"
        end)
      end

      test "a compressed message without a compression is internal, with #{content_type}" do
        run_server(HelloServer, fn port ->
          response =
            ConnectClient.request(
              port,
              :http2,
              "POST",
              "/helloworld.Greeter/SayHello",
              [{"content-type", unquote(content_type)}],
              <<1, 0::32>>
            )

          assert ConnectClient.header(response, "content-type") =~ unquote(content_type)
          assert status(response) == "13"
        end)
      end
    end
  end

  test "identity is no compression, so a compressed message with it is internal" do
    run_server(HelloServer, fn port ->
      response =
        ConnectClient.request(
          port,
          :http2,
          "POST",
          "/helloworld.Greeter/SayHello",
          [{"content-type", "application/grpc"}, {"grpc-encoding", "identity"}],
          <<1, 0::32>>
        )

      assert status(response) == "13"
    end)
  end

  # The status is in the headers of a trailers-only response, in the trailers otherwise,
  # and in the last frame of the body for gRPC-Web.
  defp status(response) do
    ConnectClient.header(response, "grpc-status") ||
      case List.keyfind(response.trailers, "grpc-status", 0) do
        {_, value} -> value
        nil -> web_status(response.body)
      end
  end

  defp web_status(body) do
    case Regex.run(~r/grpc-status: ?(\d+)/, body) do
      [_, status] -> status
      nil -> nil
    end
  end

  test "a gRPC-Web call with JSON is answered with application/grpc-web+json" do
    run_server(HelloServer, fn port ->
      response = call(port, "application/grpc-web+json", ~s({"name":"json"}))

      assert ConnectClient.header(response, "content-type") == "application/grpc-web+json"
    end)
  end
end
