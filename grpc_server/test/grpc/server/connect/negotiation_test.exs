defmodule GRPC.Server.Connect.NegotiationTest do
  use GRPC.Integration.TestCase, async: false

  import ExUnit.CaptureLog

  alias GRPC.Test.ConnectClient

  defmodule HelloServer do
    use GRPC.Server, service: Helloworld.Greeter.Service, compressors: [GRPC.Compressor.Gzip]

    def say_hello(%{name: "slow"}, _stream) do
      Process.sleep(1_000)
      %Helloworld.HelloReply{message: "late"}
    end

    def say_hello(req, _stream), do: %Helloworld.HelloReply{message: "Hello, #{req.name}"}
  end

  defp call(port, version, headers, body) do
    ConnectClient.request(
      port,
      version,
      "POST",
      "/helloworld.Greeter/SayHello",
      [{"connect-protocol-version", "1"} | headers],
      body
    )
  end

  for version <- [:http, :http2] do
    describe "negotiation over #{version}" do
      test "an unsupported content type is a 415" do
        run_server(HelloServer, fn port ->
          response =
            call(port, unquote(version), [{"content-type", "application/x-unexpected"}], "{}")

          assert response.status == 415
          assert ConnectClient.header(response, "accept-post") =~ "application/json"
        end)
      end

      test "a 415 for a client that is not Connect carries no body" do
        run_server(HelloServer, fn port ->
          response =
            ConnectClient.request(
              port,
              unquote(version),
              "POST",
              "/helloworld.Greeter/SayHello",
              [{"content-type", "image/jpeg"}],
              "{}"
            )

          assert response.status == 415
          assert response.body == ""
        end)
      end

      test "a verb other than POST is a 405" do
        run_server(HelloServer, fn port ->
          response =
            ConnectClient.request(
              port,
              unquote(version),
              "PUT",
              "/helloworld.Greeter/SayHello",
              [{"content-type", "application/json"}],
              "{}"
            )

          assert response.status == 405
          assert ConnectClient.header(response, "allow") == "POST"
        end)
      end

      test "Connect-Timeout-Ms sets a deadline" do
        run_server(HelloServer, fn port ->
          response =
            call(
              port,
              unquote(version),
              [{"content-type", "application/json"}, {"connect-timeout-ms", "50"}],
              ~s({"name":"slow"})
            )

          assert response.status == 504
          assert %{"code" => "deadline_exceeded"} = Jason.decode!(response.body)
        end)
      end

      test "a gzip request body is decompressed" do
        run_server(HelloServer, fn port ->
          response =
            call(
              port,
              unquote(version),
              [{"content-type", "application/json"}, {"content-encoding", "gzip"}],
              :zlib.gzip(~s({"name":"zipped"}))
            )

          assert response.status == 200
          assert ConnectClient.header(response, "content-encoding") == nil
          assert %{"message" => "Hello, zipped"} = Jason.decode!(response.body)
        end)
      end

      test "a response is compressed when the client accepts gzip" do
        run_server(HelloServer, fn port ->
          response =
            call(
              port,
              unquote(version),
              [{"content-type", "application/json"}, {"accept-encoding", "gzip"}],
              ~s({"name":"zipped"})
            )

          assert response.status == 200
          assert ConnectClient.header(response, "content-encoding") == "gzip"
          assert %{"message" => "Hello, zipped"} = Jason.decode!(:zlib.gunzip(response.body))
        end)
      end

      test "an unknown content encoding is unimplemented" do
        run_server(HelloServer, fn port ->
          response =
            call(
              port,
              unquote(version),
              [{"content-type", "application/json"}, {"content-encoding", "br"}],
              "{}"
            )

          assert response.status == 501
          assert %{"code" => "unimplemented"} = Jason.decode!(response.body)
        end)
      end
    end

    describe "content-type warning over #{version}" do
      for content_type <- [
            "application/proto",
            "application/json",
            "application/connect+proto",
            "application/connect+json"
          ] do
        test "#{content_type} does not log an invalid content-type warning" do
          log =
            capture_log(fn ->
              run_server(HelloServer, fn port ->
                call(port, unquote(version), [{"content-type", unquote(content_type)}], "")
              end)
            end)

          refute log =~ "invalid content-type"
        end
      end

      test "a Connect GET does not log an invalid content-type warning" do
        log =
          capture_log(fn ->
            run_server(HelloServer, fn port ->
              ConnectClient.request(
                port,
                unquote(version),
                "GET",
                "/helloworld.Greeter/SayHello?connect=v1&encoding=json&message=%7B%7D",
                [{"connect-protocol-version", "1"}]
              )
            end)
          end)

        refute log =~ "invalid content-type"
      end

      test "an unknown content type still logs the warning and gets a 415" do
        log =
          capture_log(fn ->
            run_server(HelloServer, fn port ->
              response =
                call(port, unquote(version), [{"content-type", "application/x-unexpected"}], "{}")

              assert response.status == 415
            end)
          end)

        assert log =~ "invalid content-type"
      end
    end
  end
end
