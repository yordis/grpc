defmodule GRPC.Server.Connect.GetTest do
  use GRPC.Integration.TestCase, async: false

  alias GRPC.Test.ConnectClient

  defmodule ReadService do
    @moduledoc false
    use GRPC.Service, name: "helloworld.Reader", protoc_gen_elixir_version: "0.17.1"

    rpc(:Read, Helloworld.HelloRequest, Helloworld.HelloReply, %{
      idempotency_level: :NO_SIDE_EFFECTS
    })

    rpc(:Write, Helloworld.HelloRequest, Helloworld.HelloReply)
  end

  defmodule ReadServer do
    use GRPC.Server, service: ReadService, compressors: [GRPC.Compressor.Gzip]

    def read(req, stream) do
      GRPC.Server.set_trailers(stream, %{"x-custom-trailer" => "from-server-trailer"})
      %Helloworld.HelloReply{message: "Hello, #{req.name}"}
    end

    def write(req, _stream), do: %Helloworld.HelloReply{message: "Wrote, #{req.name}"}
  end

  defp get(port, version, query, headers \\ []) do
    ConnectClient.request(
      port,
      version,
      "GET",
      "/helloworld.Reader/Read?" <> query,
      [{"connect-protocol-version", "1"} | headers]
    )
  end

  defp message(request), do: request |> Protobuf.encode() |> Base.url_encode64(padding: false)

  for version <- [:http, :http2] do
    describe "GET over #{version}" do
      test "a proto message in base64" do
        run_server(ReadServer, fn port ->
          query =
            "connect=v1&encoding=proto&base64=1&message=" <>
              message(%Helloworld.HelloRequest{name: "get"})

          response = get(port, unquote(version), query)

          assert response.status == 200
          assert ConnectClient.header(response, "content-type") == "application/proto"

          assert ConnectClient.header(response, "trailer-x-custom-trailer") ==
                   "from-server-trailer"

          assert Helloworld.HelloReply.decode(response.body).message == "Hello, get"
        end)
      end

      test "a json message in the query as it is" do
        run_server(ReadServer, fn port ->
          query =
            "connect=v1&encoding=json&message=" <>
              URI.encode_www_form(~s({"name":"get"}))

          response = get(port, unquote(version), query)

          assert response.status == 200
          assert ConnectClient.header(response, "content-type") == "application/json"
          assert %{"message" => "Hello, get"} = Jason.decode!(response.body)
        end)
      end

      test "a compressed message" do
        run_server(ReadServer, fn port ->
          compressed =
            %Helloworld.HelloRequest{name: "zip"}
            |> Protobuf.encode()
            |> :zlib.gzip()
            |> Base.url_encode64(padding: false)

          query = "connect=v1&encoding=proto&base64=1&compression=gzip&message=" <> compressed
          response = get(port, unquote(version), query)

          assert response.status == 200
          assert Helloworld.HelloReply.decode(response.body).message == "Hello, zip"
        end)
      end

      test "no message is an empty request" do
        run_server(ReadServer, fn port ->
          response = get(port, unquote(version), "connect=v1&encoding=proto")

          assert response.status == 200
          assert Helloworld.HelloReply.decode(response.body).message == "Hello, "
        end)
      end

      test "a message that is not base64 is an invalid_argument" do
        run_server(ReadServer, fn port ->
          response = get(port, unquote(version), "connect=v1&encoding=proto&base64=1&message=*")

          assert response.status == 400
          assert %{"code" => "invalid_argument"} = Jason.decode!(response.body)
        end)
      end

      test "a method that has side effects is not served" do
        run_server(ReadServer, fn port ->
          response =
            ConnectClient.request(
              port,
              unquote(version),
              "GET",
              "/helloworld.Reader/Write?connect=v1&encoding=proto",
              [{"connect-protocol-version", "1"}]
            )

          assert response.status == 405
          assert ConnectClient.header(response, "allow") == "POST"
        end)
      end

      test "POST still serves a method without side effects" do
        run_server(ReadServer, fn port ->
          response =
            ConnectClient.request(
              port,
              unquote(version),
              "POST",
              "/helloworld.Reader/Read",
              [{"content-type", "application/proto"}, {"connect-protocol-version", "1"}],
              Protobuf.encode(%Helloworld.HelloRequest{name: "post"})
            )

          assert Helloworld.HelloReply.decode(response.body).message == "Hello, post"
        end)
      end
    end
  end
end
