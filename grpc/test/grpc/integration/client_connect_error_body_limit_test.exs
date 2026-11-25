defmodule GRPC.Integration.ClientConnectErrorBodyLimitTest do
  use ExUnit.Case, async: true

  alias GRPC.Client.Adapters.{Gun, Mint}
  alias GRPC.Integration.ScriptedH2Server

  @limit 2048

  defp script(status) do
    [
      {:headers, [{":status", status}, {"content-type", "text/html"}]},
      {:data, String.duplicate("x", 1024)},
      {:data, String.duplicate("x", 1024)},
      {:data, String.duplicate("x", 1024)},
      {:data, "tail", :fin}
    ]
  end

  defp connect(port, adapter) do
    ScriptedH2Server.connect(port, adapter,
      protocol: :connect,
      max_receive_message_length: @limit,
      adapter_opts: [protocols: [:http2]]
    )
  end

  for adapter <- [Gun, Mint] do
    describe "with the #{inspect(adapter)} adapter" do
      @describetag adapter: adapter

      test "an error body over the receive limit is RESOURCE_EXHAUSTED", %{adapter: adapter} do
        port = ScriptedH2Server.start(script("500"))
        channel = connect(port, adapter)

        assert {:error, %GRPC.RPCError{status: 8, message: message}} =
                 Helloworld.Greeter.Stub.say_hello(channel, %Helloworld.HelloRequest{name: "x"})

        assert message =~ "too large"
      end

      test "an error body within the limit is still the error of the status", %{adapter: adapter} do
        port =
          ScriptedH2Server.start([
            {:headers, [{":status", "503"}, {"content-type", "text/html"}]},
            {:data, "unavailable", :fin}
          ])

        channel = connect(port, adapter)

        assert {:error, %GRPC.RPCError{status: 14}} =
                 Helloworld.Greeter.Stub.say_hello(channel, %Helloworld.HelloRequest{name: "x"})
      end
    end
  end
end
