defmodule GRPC.Server.StreamTimeoutTest do
  use GRPC.Integration.TestCase, async: false

  alias GRPC.Test.ConnectClient

  defmodule HelloServer do
    use GRPC.Server, service: Helloworld.Greeter.Service, connect: true

    def say_hello(_req, stream) do
      %Helloworld.HelloReply{message: "timeout:#{inspect(GRPC.Server.Stream.timeout_ms(stream))}"}
    end
  end

  defp say_hello(port, headers, body) do
    ConnectClient.request(
      port,
      :http2,
      "POST",
      "/helloworld.Greeter/SayHello",
      headers,
      body
    )
  end

  for content_type <- ["application/grpc", "application/grpc-web"] do
    test "the timeout of a #{content_type} request is the grpc-timeout the client sent" do
      run_server(HelloServer, fn port ->
        response =
          say_hello(
            port,
            [{"content-type", unquote(content_type)}, {"grpc-timeout", "5S"}],
            <<0, 0::32>>
          )

        assert response.body =~ "timeout:5000"
      end)
    end

    test "a #{content_type} request without a timeout has none" do
      run_server(HelloServer, fn port ->
        response = say_hello(port, [{"content-type", unquote(content_type)}], <<0, 0::32>>)

        assert response.body =~ "timeout:nil"
      end)
    end
  end

  test "the timeout of a Connect request is the connect-timeout-ms the client sent" do
    run_server(HelloServer, fn port ->
      response =
        say_hello(
          port,
          [
            {"content-type", "application/json"},
            {"connect-protocol-version", "1"},
            {"connect-timeout-ms", "1500"}
          ],
          ~s({"name":"x"})
        )

      assert %{"message" => "timeout:1500"} = Jason.decode!(response.body)
    end)
  end

  test "a Connect request without a timeout has none" do
    run_server(HelloServer, fn port ->
      response =
        say_hello(
          port,
          [{"content-type", "application/json"}, {"connect-protocol-version", "1"}],
          ~s({"name":"x"})
        )

      assert %{"message" => "timeout:nil"} = Jason.decode!(response.body)
    end)
  end
end
