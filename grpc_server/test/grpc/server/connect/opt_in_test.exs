defmodule GRPC.Server.Connect.OptInTest do
  # The Connect protocol is served only by a server that sets `connect: true`. For any
  # other server a request keeps the protocol it had before Connect existed, so a JSON
  # POST to a gRPC path is still a transcoded call with gRPC error trailers.
  use GRPC.Integration.TestCase, async: false

  alias GRPC.Test.ConnectClient

  defmodule PlainServer do
    use GRPC.Server, service: Transcode.Messaging.Service, http_transcode: true

    def create_message(%{name: "missing"}, _stream) do
      raise GRPC.RPCError, status: :not_found, message: "no such name"
    end

    def create_message(req, _stream), do: %Transcode.Message{name: req.name, text: "created"}
  end

  defmodule ConnectServer do
    use GRPC.Server,
      service: Transcode.Messaging.Service,
      http_transcode: true,
      connect: true

    def create_message(%{name: "missing"}, _stream) do
      raise GRPC.RPCError, status: :not_found, message: "no such name"
    end

    def create_message(req, _stream), do: %Transcode.Message{name: req.name, text: "created"}
  end

  @path "/transcode.Messaging/CreateMessage"

  defp post(port, version, content_type, body) do
    ConnectClient.request(
      port,
      version,
      "POST",
      @path,
      [{"content-type", content_type}],
      body
    )
  end

  defp grpc_status(response) do
    case List.keyfind(response.headers ++ response.trailers, "grpc-status", 0) do
      {_, status} -> status
      nil -> nil
    end
  end

  for version <- [:http, :http2] do
    describe "over #{version}" do
      test "a server without connect: true keeps transcoding a JSON POST" do
        run_server(PlainServer, fn port ->
          response = post(port, unquote(version), "application/json", ~s({"name":"missing"}))

          assert response.status == 404
          assert grpc_status(response) == "5"
          refute response.body =~ "not_found"
        end)
      end

      test "a server without connect: true answers a JSON POST as it did" do
        run_server(PlainServer, fn port ->
          response = post(port, unquote(version), "application/json", ~s({"name":"Ann"}))

          assert response.status == 200
          assert response.body =~ "created"
        end)
      end

      test "a server without connect: true does not answer a Connect stream content type" do
        run_server(PlainServer, fn port ->
          response = post(port, unquote(version), "application/connect+json", "{}")

          refute ConnectClient.header(response, "content-type") =~ "application/connect"
        end)
      end

      test "a server with connect: true answers the same JSON POST as Connect" do
        run_server(ConnectServer, fn port ->
          response = post(port, unquote(version), "application/json", ~s({"name":"missing"}))

          assert response.status == 404
          assert grpc_status(response) == nil
          assert response.body =~ ~s("code":"not_found")
        end)
      end
    end
  end
end
