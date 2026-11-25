defmodule Conformance.Client.CallTest do
  use ExUnit.Case, async: true

  alias Connectrpc.Conformance.V1.ClientCompatRequest
  alias Conformance.Client.{Call, Main}

  # Up to `Main.max_in_flight/0` cases run at once, all of them possibly on one shared
  # HTTP/1.1 channel. With at least as many connections, no call waits for a connection.
  for protocol <- [:PROTOCOL_CONNECT, :PROTOCOL_GRPC_WEB],
      version <- [:HTTP_VERSION_1, :HTTP_VERSION_UNSPECIFIED] do
    test "a #{protocol} #{version} channel opens a connection for every case in flight" do
      req = %ClientCompatRequest{
        host: "127.0.0.1",
        port: 1,
        protocol: unquote(protocol),
        http_version: unquote(version)
      }

      opts = Call.connect_opts(req, GRPC.Client.Adapters.Mint)
      assert opts[:adapter_opts][:http1_max_connections] >= Main.max_in_flight()
    end
  end
end
