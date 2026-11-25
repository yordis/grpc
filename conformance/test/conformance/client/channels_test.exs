defmodule Conformance.Client.ChannelsTest do
  use ExUnit.Case, async: true

  alias Connectrpc.Conformance.V1.ClientCompatRequest
  alias Connectrpc.Conformance.V1.ClientCompatRequest.Cancel
  alias Conformance.Client.Channels

  # Stands in for `GRPC.Stub.connect/2`: counts connects and answers with what `reply` says.
  # `ready` stands in for `GRPC.Client.Connection.await_ready/2`, and the test process for
  # the connection process of every channel.
  defp start_channels(reply \\ fn n -> {:ok, {:channel, n}} end, ready \\ fn _ -> :ok end) do
    test = self()
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    connect = fn addr, opts ->
      n = Agent.get_and_update(counter, &{&1 + 1, &1 + 1})
      send(opts[:test], {:connected, addr, n})
      reply.(n)
    end

    {:ok, channels} =
      Channels.start_link(connect: connect, ready: ready, connection: fn _ -> test end)

    channels
  end

  test "cases with the same address and options share one channel" do
    channels = start_channels()
    opts = [test: self(), adapter: :mint]

    assert {:ok, {:channel, 1}} = Channels.checkout(channels, "127.0.0.1:1", opts)
    assert {:ok, {:channel, 1}} = Channels.checkout(channels, "127.0.0.1:1", opts)
    assert_received {:connected, "127.0.0.1:1", 1}
    refute_received {:connected, _, _}
  end

  test "another address or other options get their own channel" do
    channels = start_channels()

    assert {:ok, {:channel, 1}} = Channels.checkout(channels, "127.0.0.1:1", test: self())
    assert {:ok, {:channel, 2}} = Channels.checkout(channels, "127.0.0.1:2", test: self())

    assert {:ok, {:channel, 3}} =
             Channels.checkout(channels, "127.0.0.1:1", test: self(), codec: :json)
  end

  test "a failed connect is not kept, the next case connects again" do
    channels = start_channels(fn n -> if n == 1, do: {:error, :refused}, else: {:ok, n} end)

    assert {:error, :refused} = Channels.checkout(channels, "127.0.0.1:1", test: self())
    assert {:ok, 2} = Channels.checkout(channels, "127.0.0.1:1", test: self())
  end

  test "a connect that raises fails that case and the store keeps serving" do
    channels = start_channels(fn n -> if n == 1, do: raise("boom"), else: {:ok, n} end)

    assert {:error, %RuntimeError{message: "boom"}} =
             Channels.checkout(channels, "127.0.0.1:1", test: self())

    assert Process.alive?(channels)
    assert {:ok, 2} = Channels.checkout(channels, "127.0.0.1:1", test: self())
  end

  test "a connect that exits fails that case and the store keeps serving" do
    channels = start_channels(fn n -> if n == 1, do: exit(:gone), else: {:ok, n} end)

    assert {:error, {:exit, :gone}} = Channels.checkout(channels, "127.0.0.1:1", test: self())
    assert {:ok, 2} = Channels.checkout(channels, "127.0.0.1:1", test: self())
  end

  test "a kept channel whose connection is no longer running is replaced" do
    ready = fn
      {:channel, 1} -> {:error, :not_started}
      _ -> :ok
    end

    channels = start_channels(fn n -> {:ok, {:channel, n}} end, ready)

    assert {:ok, {:channel, 1}} = Channels.checkout(channels, "127.0.0.1:1", test: self())
    assert {:ok, {:channel, 2}} = Channels.checkout(channels, "127.0.0.1:1", test: self())
    assert {:ok, {:channel, 2}} = Channels.checkout(channels, "127.0.0.1:1", test: self())
  end

  # The reference client's transports never die. A kept channel whose connection process
  # is gone is dropped, so no case gets it, and the next case connects again.
  test "a kept channel whose connection process exits is dropped and the next case reconnects" do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    connect = fn _addr, _opts ->
      n = Agent.get_and_update(counter, &{&1 + 1, &1 + 1})
      {:ok, {:channel, n, spawn(fn -> Process.sleep(:infinity) end)}}
    end

    {:ok, channels} =
      Channels.start_link(
        connect: connect,
        ready: fn _ -> :ok end,
        connection: fn {:channel, _, pid} -> pid end
      )

    assert {:ok, {:channel, 1, pid}} = Channels.checkout(channels, "127.0.0.1:1", [])
    assert {:ok, {:channel, 1, ^pid}} = Channels.checkout(channels, "127.0.0.1:1", [])

    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}

    assert {:ok, {:channel, 2, _}} = Channels.checkout(channels, "127.0.0.1:1", [])
    assert {:ok, {:channel, 2, _}} = Channels.checkout(channels, "127.0.0.1:1", [])
    assert Process.alive?(channels)
  end

  test "a kept channel is handed out once its connection is ready again" do
    parent = self()

    ready = fn channel ->
      send(parent, {:awaited, channel})
      :ok
    end

    channels = start_channels(fn n -> {:ok, {:channel, n}} end, ready)

    assert {:ok, {:channel, 1}} = Channels.checkout(channels, "127.0.0.1:1", test: self())
    assert {:ok, {:channel, 1}} = Channels.checkout(channels, "127.0.0.1:1", test: self())
    assert_received {:awaited, {:channel, 1}}
  end

  describe "shared?/1" do
    # The reference client gives an HTTP/1.1 case that may end its call early a connection
    # of its own, so a cancelled call never takes down a connection another case uses.
    test "an HTTP/1.1 case with a cancel or a timeout has a channel of its own" do
      refute Channels.shared?(%ClientCompatRequest{
               http_version: :HTTP_VERSION_1,
               cancel: %Cancel{}
             })

      refute Channels.shared?(%ClientCompatRequest{http_version: :HTTP_VERSION_1, timeout_ms: 10})
    end

    test "other cases share" do
      assert Channels.shared?(%ClientCompatRequest{http_version: :HTTP_VERSION_1})

      assert Channels.shared?(%ClientCompatRequest{
               http_version: :HTTP_VERSION_2,
               cancel: %Cancel{},
               timeout_ms: 10
             })
    end
  end
end
