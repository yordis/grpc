defmodule GRPC.Server.ReplySizeTest do
  use GRPC.Integration.TestCase, async: false

  alias GRPC.Test.ConnectClient

  defmodule HelloServer do
    use GRPC.Server, service: Helloworld.Greeter.Service

    def say_hello(_req, _stream), do: %Helloworld.HelloReply{message: String.duplicate("x", 300)}
  end

  setup do
    Application.put_env(:grpc, :max_message_length, 100)
    on_exit(fn -> Application.delete_env(:grpc, :max_message_length) end)
    on_exit(fn -> Application.delete_env(:grpc, :max_send_message_length) end)
  end

  # The limit of what the server sends is its own, and does not follow the receive limit.
  for content_type <- ["application/grpc", "application/grpc-web"] do
    test "a reply over the receive limit is sent when the send limit is higher, with #{content_type}" do
      Application.put_env(:grpc, :max_send_message_length, 1_000)

      run_server(HelloServer, fn port ->
        response =
          ConnectClient.request(
            port,
            :http2,
            "POST",
            "/helloworld.Greeter/SayHello",
            [{"content-type", unquote(content_type)}],
            <<0, 0::32>>
          )

        assert byte_size(response.body) > 300
        refute response.body =~ "resource_exhausted"
        refute response.body =~ "too large"
      end)
    end
  end

  for content_type <- ["application/grpc", "application/grpc-web"] do
    test "a reply over the receive limit is sent when no send limit is set, with #{content_type}" do
      run_server(HelloServer, fn port ->
        response =
          ConnectClient.request(
            port,
            :http2,
            "POST",
            "/helloworld.Greeter/SayHello",
            [{"content-type", unquote(content_type)}],
            <<0, 0::32>>
          )

        assert byte_size(response.body) > 300
        refute response.body =~ "too large"
      end)
    end
  end
end
