defmodule GRPC.Integration.ClientCorruptReplyTest do
  use ExUnit.Case, async: true

  alias GRPC.Client.Adapters.{Gun, Mint}
  alias GRPC.Integration.ScriptedH2Server

  @garbage "this is not gzip data"

  defp frame(garbage), do: <<1, byte_size(garbage)::32, garbage::binary>>

  defp script(:grpc) do
    [
      {:headers,
       [{":status", "200"}, {"content-type", "application/grpc"}, {"grpc-encoding", "gzip"}]},
      {:data, frame(@garbage)},
      {:headers, [{"grpc-status", "0"}], :fin}
    ]
  end

  defp script(:grpc_web) do
    [
      {:headers,
       [
         {":status", "200"},
         {"content-type", "application/grpc-web+proto"},
         {"grpc-encoding", "gzip"}
       ]},
      {:data, frame(@garbage)},
      {:data, <<0x80, 16::32, "grpc-status: 0\r\n\r\n">>, :fin}
    ]
  end

  defp script(:connect) do
    [
      {:headers,
       [
         {":status", "200"},
         {"content-type", "application/proto"},
         {"content-encoding", "gzip"}
       ]},
      {:data, @garbage, :fin}
    ]
  end

  defp connect(port, adapter, protocol) do
    ScriptedH2Server.connect(port, adapter,
      protocol: protocol,
      accepted_compressors: [GRPC.Compressor.Gzip],
      adapter_opts: [protocols: [:http2]]
    )
  end

  for adapter <- [Gun, Mint], protocol <- [:grpc, :grpc_web, :connect] do
    describe "with the #{inspect(adapter)} adapter over #{protocol}" do
      @describetag adapter: adapter, protocol: protocol

      test "a corrupt compressed unary reply is an INTERNAL error, the caller survives", %{
        adapter: adapter,
        protocol: protocol
      } do
        port = ScriptedH2Server.start(script(protocol))
        channel = connect(port, adapter, protocol)
        caller = self()

        assert {:error, %GRPC.RPCError{status: 13, message: "Message could not be decompressed."}} =
                 Helloworld.Greeter.Stub.say_hello(channel, %Helloworld.HelloRequest{name: "x"})

        assert Process.alive?(caller)
      end
    end
  end
end
