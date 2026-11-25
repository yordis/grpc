defmodule GRPC.Integration.ClientStreamResetStatusTest do
  use ExUnit.Case, async: true

  alias GRPC.Client.Adapters.{Gun, Mint}
  alias GRPC.Integration.ScriptedH2Server

  # https://github.com/grpc/grpc/blob/master/doc/PROTOCOL-HTTP2.md#errors
  # {HTTP/2 error code, name, gRPC status}
  @mapping [
    {0, "NO_ERROR", GRPC.Status.internal()},
    {1, "PROTOCOL_ERROR", GRPC.Status.internal()},
    {2, "INTERNAL_ERROR", GRPC.Status.internal()},
    {3, "FLOW_CONTROL_ERROR", GRPC.Status.internal()},
    {4, "SETTINGS_TIMEOUT", GRPC.Status.internal()},
    {5, "STREAM_CLOSED", GRPC.Status.internal()},
    {6, "FRAME_SIZE_ERROR", GRPC.Status.internal()},
    {7, "REFUSED_STREAM", GRPC.Status.unavailable()},
    {8, "CANCEL", GRPC.Status.cancelled()},
    {9, "COMPRESSION_ERROR", GRPC.Status.internal()},
    {10, "CONNECT_ERROR", GRPC.Status.internal()},
    {11, "ENHANCE_YOUR_CALM", GRPC.Status.resource_exhausted()},
    {12, "INADEQUATE_SECURITY", GRPC.Status.permission_denied()},
    {13, "HTTP_1_1_REQUIRED", GRPC.Status.internal()}
  ]

  defp assert_clean_message(message) do
    refute message =~ "Mint"
    refute message =~ "%"
    refute message =~ "stream_error"
    refute message =~ "{"
  end

  for adapter <- [Gun, Mint], {code, name, status} <- @mapping do
    describe "with the #{inspect(adapter)} adapter and a server reset with #{name}" do
      @describetag adapter: adapter, code: code, status: status

      test "a unary call fails with the mapped status", ctx do
        port = ScriptedH2Server.start([{:rst, ctx.code}])
        channel = ScriptedH2Server.connect(port, ctx.adapter)

        assert {:error, %GRPC.RPCError{status: status, message: message}} =
                 Helloworld.Greeter.Stub.say_hello(channel, %Helloworld.HelloRequest{name: "x"})

        assert status == ctx.status
        assert_clean_message(message)
      end

      test "a server stream fails with the mapped status", ctx do
        port =
          ScriptedH2Server.start([
            {:headers, [{":status", "200"}, {"content-type", "application/grpc"}]},
            {:rst, ctx.code}
          ])

        channel = ScriptedH2Server.connect(port, ctx.adapter)

        {:ok, replies} =
          Routeguide.RouteGuide.Stub.list_features(channel, %Routeguide.Rectangle{})

        assert [{:error, %GRPC.RPCError{status: status, message: message}}] =
                 Enum.to_list(replies)

        assert status == ctx.status
        assert_clean_message(message)
      end
    end
  end
end
