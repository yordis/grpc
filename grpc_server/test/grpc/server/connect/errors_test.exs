defmodule GRPC.Server.Connect.ErrorsTest do
  use GRPC.Integration.TestCase, async: false

  alias GRPC.Test.ConnectClient

  defmodule HelloServer do
    use GRPC.Server, service: Helloworld.Greeter.Service, connect: true

    def say_hello(%{name: "error:" <> code}, stream) do
      GRPC.Server.set_headers(stream, %{"x-custom-header" => "from-server"})
      GRPC.Server.set_trailers(stream, %{"x-custom-trailer" => "from-server-trailer"})

      detail = %Google.Protobuf.Any{
        type_url: "type.googleapis.com/helloworld.HelloReply",
        value: Protobuf.encode(%Helloworld.HelloReply{message: "detail"})
      }

      raise GRPC.RPCError,
        status: String.to_existing_atom(code),
        message: "it failed",
        details: [detail]
    end

    def say_hello(%{name: "crash"}, _stream), do: raise("boom")

    def say_hello(req, _stream), do: %Helloworld.HelloReply{message: "Hello, #{req.name}"}
  end

  @statuses [
    {:cancelled, "canceled", 499},
    {:unknown, "unknown", 500},
    {:invalid_argument, "invalid_argument", 400},
    {:deadline_exceeded, "deadline_exceeded", 504},
    {:not_found, "not_found", 404},
    {:already_exists, "already_exists", 409},
    {:permission_denied, "permission_denied", 403},
    {:resource_exhausted, "resource_exhausted", 429},
    {:failed_precondition, "failed_precondition", 400},
    {:aborted, "aborted", 409},
    {:out_of_range, "out_of_range", 400},
    {:unimplemented, "unimplemented", 501},
    {:internal, "internal", 500},
    {:unavailable, "unavailable", 503},
    {:data_loss, "data_loss", 500},
    {:unauthenticated, "unauthenticated", 401}
  ]

  @detail_value Base.encode64(Protobuf.encode(%Helloworld.HelloReply{message: "detail"}),
                  padding: false
                )

  defp call(port, version, content_type, body) do
    ConnectClient.request(
      port,
      version,
      "POST",
      "/helloworld.Greeter/SayHello",
      [{"content-type", content_type}, {"connect-protocol-version", "1"}],
      body
    )
  end

  for version <- [:http, :http2] do
    describe "unary errors over #{version}" do
      for {status, code, http_status} <- @statuses do
        test "#{code} is a #{http_status} with a JSON body" do
          run_server(HelloServer, fn port ->
            response =
              call(
                port,
                unquote(version),
                "application/json",
                ~s({"name":"error:#{unquote(status)}"})
              )

            assert response.status == unquote(http_status)
            assert ConnectClient.header(response, "content-type") == "application/json"

            assert %{"code" => unquote(code), "message" => "it failed", "details" => [detail]} =
                     Jason.decode!(response.body)

            assert detail == %{"type" => "helloworld.HelloReply", "value" => @detail_value}
          end)
        end
      end

      test "an error replies in JSON whatever the codec of the request, with headers and trailers" do
        run_server(HelloServer, fn port ->
          body = Protobuf.encode(%Helloworld.HelloRequest{name: "error:not_found"})
          response = call(port, unquote(version), "application/proto", body)

          assert response.status == 404
          assert ConnectClient.header(response, "content-type") == "application/json"
          assert ConnectClient.header(response, "x-custom-header") == "from-server"

          assert ConnectClient.header(response, "trailer-x-custom-trailer") ==
                   "from-server-trailer"

          assert %{"code" => "not_found"} = Jason.decode!(response.body)
        end)
      end

      test "an error without details has no details field" do
        run_server(HelloServer, fn port ->
          response = call(port, unquote(version), "application/json", ~s({"name":"crash"}))

          assert response.status == 500
          body = Jason.decode!(response.body)
          assert body["code"] == "unknown"
          refute Map.has_key?(body, "details")
        end)
      end

      test "a body that is not a message is an invalid_argument" do
        run_server(HelloServer, fn port ->
          response = call(port, unquote(version), "application/json", "not json")

          assert response.status == 400
          assert %{"code" => "invalid_argument"} = Jason.decode!(response.body)
        end)
      end
    end
  end
end
