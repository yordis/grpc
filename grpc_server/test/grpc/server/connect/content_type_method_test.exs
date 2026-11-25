defmodule GRPC.Server.Connect.ContentTypeMethodTest do
  # A unary Connect content type belongs to a unary method, and a streaming one to a
  # streaming method. The other pairing is refused with HTTP 415 before the handler runs.
  use GRPC.Integration.TestCase, async: false

  alias GRPC.Test.ConnectClient

  defmodule RouteServer do
    use GRPC.Server, service: Routeguide.RouteGuide.Service, connect: true

    def get_feature(_point, _stream), do: %Routeguide.Feature{name: "one"}

    def list_features(_rect, stream) do
      for name <- ~w(a b c), do: GRPC.Server.send_reply(stream, %Routeguide.Feature{name: name})
    end

    def record_route(req_enum, _stream) do
      %Routeguide.RouteSummary{point_count: Enum.count(req_enum)}
    end

    def route_chat(req_enum, stream) do
      Enum.each(req_enum, &GRPC.Server.send_reply(stream, &1))
    end
  end

  @service "/routeguide.RouteGuide/"

  defp post(port, version, method, content_type, body) do
    ConnectClient.request(
      port,
      version,
      "POST",
      @service <> method,
      [{"content-type", content_type}, {"connect-protocol-version", "1"}],
      body
    )
  end

  for version <- [:http, :http2] do
    describe "over #{version}" do
      for {method, type} <- [
            {"ListFeatures", "server-streaming"},
            {"RecordRoute", "client-streaming"},
            {"RouteChat", "bidirectional"}
          ],
          content_type <- ["application/proto", "application/json"] do
        test "#{content_type} on a #{type} method is refused with 415" do
          run_server(RouteServer, fn port ->
            response = post(port, unquote(version), unquote(method), unquote(content_type), "{}")

            assert response.status == 415
            assert response.body =~ ~s("code")
          end)
        end
      end

      for content_type <- ["application/connect+proto", "application/connect+json"] do
        test "#{content_type} on a unary method is refused with 415" do
          run_server(RouteServer, fn port ->
            response = post(port, unquote(version), "GetFeature", unquote(content_type), "")

            assert response.status == 415
            assert response.body =~ ~s("code")
          end)
        end
      end

      test "the matching content types are still served" do
        run_server(RouteServer, fn port ->
          assert %{status: 200} =
                   post(port, unquote(version), "GetFeature", "application/json", "{}")

          assert %{status: 200} =
                   post(port, unquote(version), "ListFeatures", "application/connect+json", "")
        end)
      end
    end
  end
end
