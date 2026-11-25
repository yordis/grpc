defmodule GRPC.Server.Adapters.CowboyRequestTimeoutTest do
  # An HTTP/1.1 client that connects and sends nothing must not hold a connection forever,
  # while `:idle_timeout` stays `:infinity` for long calls.
  use GRPC.Integration.TestCase, async: false

  defmodule HelloServer do
    use GRPC.Server, service: Helloworld.Greeter.Service

    def say_hello(req, _stream), do: %Helloworld.HelloReply{message: "Hello, #{req.name}"}
  end

  test "an HTTP/1.1 connection that sends no request is closed after request_timeout" do
    run_server(
      HelloServer,
      fn port ->
        {:ok, socket} = :gen_tcp.connect(~c"localhost", port, [:binary, active: false])
        assert {:error, :closed} = :gen_tcp.recv(socket, 0, 2_000)
      end,
      0,
      adapter_opts: [request_timeout: 200]
    )
  end
end
