defmodule GRPC.Server.Connect.UnaryTest do
  use GRPC.Integration.TestCase, async: false

  alias GRPC.Test.ConnectClient

  defmodule HelloServer do
    use GRPC.Server, service: Helloworld.Greeter.Service

    def say_hello(req, stream) do
      GRPC.Server.set_headers(stream, %{"x-custom-header" => "from-server"})
      GRPC.Server.set_trailers(stream, %{"x-custom-trailer" => "from-server-trailer"})

      %Helloworld.HelloReply{message: "Hello, #{req.name}"}
    end
  end

  for version <- [:http, :http2] do
    describe "unary over #{version}" do
      test "serves application/proto" do
        run_server(HelloServer, fn port ->
          body = Protobuf.encode(%Helloworld.HelloRequest{name: "connect"})

          response =
            ConnectClient.request(
              port,
              unquote(version),
              "POST",
              "/helloworld.Greeter/SayHello",
              [{"content-type", "application/proto"}, {"connect-protocol-version", "1"}],
              body
            )

          assert response.status == 200
          assert ConnectClient.header(response, "content-type") == "application/proto"
          assert ConnectClient.header(response, "x-custom-header") == "from-server"

          assert ConnectClient.header(response, "trailer-x-custom-trailer") ==
                   "from-server-trailer"

          assert Helloworld.HelloReply.decode(response.body).message == "Hello, connect"
        end)
      end

      test "serves application/json" do
        run_server(HelloServer, fn port ->
          response =
            ConnectClient.request(
              port,
              unquote(version),
              "POST",
              "/helloworld.Greeter/SayHello",
              [{"content-type", "application/json"}, {"connect-protocol-version", "1"}],
              ~s({"name":"connect"})
            )

          assert response.status == 200
          assert ConnectClient.header(response, "content-type") == "application/json"
          assert ConnectClient.header(response, "x-custom-header") == "from-server"

          assert ConnectClient.header(response, "trailer-x-custom-trailer") ==
                   "from-server-trailer"

          assert %{"message" => "Hello, connect"} = Jason.decode!(response.body)
        end)
      end
    end
  end
end
