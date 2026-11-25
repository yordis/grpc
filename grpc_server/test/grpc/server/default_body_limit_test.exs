defmodule GRPC.Server.DefaultBodyLimitTest do
  # `:max_body_size` is 4 MiB when a server starts without it, through `start_endpoint/3`.
  use ExUnit.Case, async: false

  alias GRPC.Test.ConnectClient

  @four_mib 4 * 1024 * 1024

  defmodule HelloServer do
    use GRPC.Server, service: Helloworld.Greeter.Service

    def say_hello(_req, _stream), do: %Helloworld.HelloReply{message: "ok"}
  end

  defmodule Endpoint do
    use GRPC.Endpoint
    run(HelloServer)
  end

  defp with_endpoint(opts, fun) do
    {:ok, _pid, port} = GRPC.Server.start_endpoint(Endpoint, 0, opts)

    try do
      fun.(port)
    after
      :ok = GRPC.Server.stop_endpoint(Endpoint)
    end
  end

  defp grpc_status(port, size) do
    body = <<0, size::32, :binary.copy(<<0>>, size)::binary>>

    response =
      ConnectClient.request(
        port,
        :http2,
        "POST",
        "/helloworld.Greeter/SayHello",
        [{"content-type", "application/grpc"}],
        body
      )

    List.keyfind(response.headers ++ response.trailers, "grpc-status", 0)
  end

  test "a body over 4 MiB is refused when the server starts without :max_body_size" do
    with_endpoint([], fn port ->
      assert {"grpc-status", "8"} = grpc_status(port, @four_mib + 1)
    end)
  end

  test "a body over 4 MiB is refused when :max_body_size is nil" do
    with_endpoint([max_body_size: nil], fn port ->
      assert {"grpc-status", "8"} = grpc_status(port, @four_mib + 1)
    end)
  end

  test "a body over 4 MiB is accepted when :max_body_size is higher" do
    with_endpoint([max_body_size: 2 * @four_mib], fn port ->
      refute {"grpc-status", "8"} == grpc_status(port, @four_mib + 1)
    end)
  end

  test "a body of any size is accepted when :max_body_size is :infinity" do
    with_endpoint([max_body_size: :infinity], fn port ->
      refute {"grpc-status", "8"} == grpc_status(port, @four_mib + 1)
    end)
  end
end
