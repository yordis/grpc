defmodule GRPC.Integration.ClientHttpStatusTest do
  use ExUnit.Case, async: true

  alias GRPC.Client.Adapters.{Gun, Mint}
  alias GRPC.Integration.ScriptedH2Server

  # https://github.com/grpc/grpc/blob/master/doc/http-grpc-status-mapping.md
  @mapping [
    {400, GRPC.Status.internal()},
    {401, GRPC.Status.unauthenticated()},
    {403, GRPC.Status.permission_denied()},
    {404, GRPC.Status.unimplemented()},
    {429, GRPC.Status.unavailable()},
    {502, GRPC.Status.unavailable()},
    {503, GRPC.Status.unavailable()},
    {504, GRPC.Status.unavailable()},
    {418, GRPC.Status.unknown()},
    {505, GRPC.Status.unknown()}
  ]

  defp connect(port, adapter) do
    {:ok, channel} = GRPC.Stub.connect("localhost:#{port}", adapter: adapter)
    channel
  end

  for adapter <- [Gun, Mint], {http_status, grpc_status} <- @mapping do
    describe "with the #{inspect(adapter)} adapter and HTTP #{http_status}" do
      @describetag adapter: adapter, http_status: http_status, grpc_status: grpc_status

      test "a unary call without grpc-status fails with the mapped status", ctx do
        port =
          ScriptedH2Server.start([
            {:headers, [{":status", "#{ctx.http_status}"}, {"content-type", "text/plain"}], :fin}
          ])

        channel = connect(port, ctx.adapter)

        assert {:error, %GRPC.RPCError{status: status}} =
                 Helloworld.Greeter.Stub.say_hello(channel, %Helloworld.HelloRequest{name: "x"})

        assert status == ctx.grpc_status
      end

      test "a server stream without grpc-status fails with the mapped status", ctx do
        port =
          ScriptedH2Server.start([
            {:headers, [{":status", "#{ctx.http_status}"}, {"content-type", "text/plain"}]},
            {:data, "nope", :fin}
          ])

        channel = connect(port, ctx.adapter)

        result = Routeguide.RouteGuide.Stub.list_features(channel, %Routeguide.Rectangle{})

        error =
          case result do
            {:error, error} ->
              error

            {:ok, replies} ->
              Enum.find_value(replies, fn
                {:error, e} -> e
                _ -> nil
              end)
          end

        assert %GRPC.RPCError{status: status} = error
        assert status == ctx.grpc_status
      end
    end
  end
end
