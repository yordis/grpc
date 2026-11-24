defmodule GRPC.Integration.ErrorMetadataTest do
  use GRPC.Integration.TestCase

  alias GRPC.Integration.RawHTTP2

  defmodule Server do
    use GRPC.Server, service: Helloworld.Greeter.Service

    def say_hello(_req, stream) do
      GRPC.Server.set_headers(stream, %{"x-custom-header" => "from-header"})
      GRPC.Server.set_trailers(stream, %{"x-custom-trailer" => "from-trailer"})
      raise GRPC.RPCError, status: GRPC.Status.invalid_argument(), message: "bad"
    end
  end

  defp call(port) do
    RawHTTP2.unary(
      port,
      "/helloworld.Greeter/SayHello",
      Helloworld.HelloRequest.encode(%Helloworld.HelloRequest{name: "x"})
    )
  end

  test "trailers set before an error is raised are sent with the error" do
    run_server(Server, fn port ->
      response = call(port)
      # The error is the whole response, so the trailers may arrive in the headers frame.
      metadata = response.headers ++ response.trailers

      assert {"grpc-status", "3"} in metadata
      assert {"grpc-message", "bad"} in metadata
      assert {"x-custom-trailer", "from-trailer"} in metadata
    end)
  end

  test "headers set before an error is raised are sent with the error" do
    run_server(Server, fn port ->
      response = call(port)

      assert {"x-custom-header", "from-header"} in response.headers
    end)
  end

  test "headers set before an error is raised are sent in a headers frame ahead of the error trailers" do
    run_server(Server, fn port ->
      response = call(port)

      refute List.keymember?(response.headers, "grpc-status", 0)
      assert {"grpc-status", "3"} in response.trailers
      assert {"x-custom-trailer", "from-trailer"} in response.trailers
    end)
  end
end
