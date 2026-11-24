defmodule GRPC.Server.Adapters.CowboyTest do
  use ExUnit.Case, async: true

  alias GRPC.Server.Adapters.Cowboy

  describe "child_spec/4" do
    test "produces the correct socket opts for ranch_tcp for inet" do
      spec =
        Cowboy.child_spec(:endpoint, [], 8080, [
          {:adapter_opts,
           [
             {:foo, :bar},
             {:ip, {127, 0, 0, 1}},
             {:ipv6_v6only, false},
             {:net, :inet},
             {:baz, :foo}
           ]}
        ])

      socket_opts = get_socket_opts_from_child_spec(spec)

      assert Enum.sort(socket_opts) ==
               Enum.sort([:inet, {:ip, {127, 0, 0, 1}}, {:ipv6_v6only, false}, {:port, 8080}])
    end

    test "produces the correct socket opts for ranch_tcp for inet6" do
      spec =
        Cowboy.child_spec(:endpoint, [], 8081, [
          {:adapter_opts,
           [
             {:foo, :bar},
             {:ip, {0, 0, 0, 0, 0, 0, 0, 1}},
             {:ipv6_v6only, true},
             {:net, :inet6},
             {:baz, :foo}
           ]}
        ])

      socket_opts = get_socket_opts_from_child_spec(spec)

      assert Enum.sort(socket_opts) ==
               Enum.sort([
                 :inet6,
                 {:ip, {0, 0, 0, 0, 0, 0, 0, 1}},
                 {:ipv6_v6only, true},
                 {:port, 8081}
               ])
    end
  end

  describe "timeouts" do
    # Cowboy closes an HTTP/1.1 connection that is idle between requests after
    # `request_timeout`, 5 seconds by default. A client that reuses the connection at that
    # moment fails with "server closed idle connection".
    test "an idle HTTP/1.1 connection is kept as long as an idle HTTP/2 one" do
      assert %{request_timeout: :infinity, idle_timeout: :infinity} = protocol_opts([])
    end

    test "idle_timeout sets the time of an idle HTTP/1.1 connection too" do
      assert %{request_timeout: 1_000, idle_timeout: 1_000} =
               protocol_opts(idle_timeout: 1_000)
    end

    test "request_timeout can be set on its own" do
      assert %{request_timeout: 2_000, idle_timeout: :infinity} =
               protocol_opts(request_timeout: 2_000)
    end

    defp protocol_opts(adapter_opts) do
      spec = Cowboy.child_spec(:endpoint, [], 8082, adapter_opts: adapter_opts)
      {_, _, [_scheme, _endpoint, _servers, _port, {_, _, start_opts}]} = spec.start
      [_ref, _transport, _transport_opts, _protocol, opts_map] = start_opts
      opts_map
    end
  end

  defp get_socket_opts_from_child_spec(spec) do
    # The adapter's start_link/5 wraps the real ranch mfa as its last argument
    {_Cowboy, _start_link, [_scheme, _endpoint, _servers, _port, {_, _, start_opts}]} =
      spec.start

    # start_opts is the ranch listener args:
    # [ref, transport, trans_opts, protocol, proto_opts]
    # where ref might be a string in newer ranch versions
    [_ref, _ranch_tcp, transport_opts_map, _cowboy_clear, _opts_map] = start_opts
    transport_opts_map.socket_opts
  end
end
