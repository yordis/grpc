defmodule GRPC.Integration.ClientDeadlineResetTest do
  use ExUnit.Case, async: true

  alias GRPC.Client.Adapters.{Gun, Mint}
  alias GRPC.Integration.ScriptedH2Server

  @deadline_exceeded GRPC.Status.deadline_exceeded()
  @cancel 8

  # A server enforces the deadline it was sent, and does so a little after the client
  # does, resetting the stream with CANCEL. That reset is the deadline, whichever of
  # the two notices it first.
  for adapter <- [Gun, Mint] do
    describe "with the #{inspect(adapter)} adapter" do
      @describetag adapter: adapter

      test "a server reset with CANCEL as the deadline arrives is DEADLINE_EXCEEDED",
           %{adapter: adapter} do
        port = ScriptedH2Server.start([{:sleep, 510}, {:rst, @cancel}])
        channel = ScriptedH2Server.connect(port, adapter)

        assert {:error, %GRPC.RPCError{status: @deadline_exceeded}} =
                 Helloworld.Greeter.Stub.say_hello(channel, %Helloworld.HelloRequest{name: "x"},
                   timeout: 500
                 )
      end
    end
  end
end
