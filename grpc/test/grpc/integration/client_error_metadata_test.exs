defmodule GRPC.Integration.ClientErrorMetadataTest do
  use ExUnit.Case, async: true

  alias GRPC.Client.Adapters.{Gun, Mint}
  alias GRPC.Integration.ScriptedH2Server

  @not_found GRPC.Status.not_found()

  @ok_headers [
    {":status", "200"},
    {"content-type", "application/grpc"},
    {"x-custom-header", "from-headers"}
  ]

  @error_trailers [
    {"grpc-status", "5"},
    {"grpc-message", "gone"},
    {"x-custom-trailer", "from-trailers"}
  ]

  defp connect(port, adapter) do
    channel = ScriptedH2Server.connect(port, adapter)
    channel
  end

  defp stream_error(result) do
    case result do
      {:error, error} ->
        error

      {:ok, replies} ->
        Enum.find_value(replies, fn
          {:error, e} -> e
          _ -> nil
        end)
    end
  end

  for adapter <- [Gun, Mint] do
    describe "with the #{inspect(adapter)} adapter" do
      @describetag adapter: adapter

      test "a unary error carries the response headers and the trailers", %{adapter: adapter} do
        port =
          ScriptedH2Server.start([{:headers, @ok_headers}, {:headers, @error_trailers, :fin}])

        channel = connect(port, adapter)

        assert {:error, %GRPC.RPCError{} = error} =
                 Helloworld.Greeter.Stub.say_hello(channel, %Helloworld.HelloRequest{name: "x"})

        assert error.status == @not_found
        assert error.headers["x-custom-header"] == "from-headers"
        assert error.trailers["x-custom-trailer"] == "from-trailers"
      end

      test "a trailers-only unary error carries the trailers", %{adapter: adapter} do
        port =
          ScriptedH2Server.start([
            {:headers,
             [{":status", "200"}, {"content-type", "application/grpc"}] ++ @error_trailers, :fin}
          ])

        channel = connect(port, adapter)

        assert {:error, %GRPC.RPCError{} = error} =
                 Helloworld.Greeter.Stub.say_hello(channel, %Helloworld.HelloRequest{name: "x"})

        assert error.status == @not_found
        assert error.trailers["x-custom-trailer"] == "from-trailers"
      end

      test "a server stream error carries the response headers and the trailers",
           %{adapter: adapter} do
        port =
          ScriptedH2Server.start([{:headers, @ok_headers}, {:headers, @error_trailers, :fin}])

        channel = connect(port, adapter)

        error =
          stream_error(Routeguide.RouteGuide.Stub.list_features(channel, %Routeguide.Rectangle{}))

        assert %GRPC.RPCError{status: @not_found} = error
        assert error.headers["x-custom-header"] == "from-headers"
        assert error.trailers["x-custom-trailer"] == "from-trailers"
      end

      test "an error has no headers or trailers when the server sent none", %{adapter: adapter} do
        port = ScriptedH2Server.start([{:headers, [{":status", "503"}], :fin}])
        channel = connect(port, adapter)

        assert {:error, %GRPC.RPCError{} = error} =
                 Helloworld.Greeter.Stub.say_hello(channel, %Helloworld.HelloRequest{name: "x"})

        assert error.headers == nil
        assert error.trailers == nil
      end
    end
  end
end
