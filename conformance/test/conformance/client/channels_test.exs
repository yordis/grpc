defmodule Conformance.Client.ChannelsTest do
  use ExUnit.Case, async: true

  alias Connectrpc.Conformance.V1.ClientCompatRequest
  alias Connectrpc.Conformance.V1.ClientCompatRequest.Cancel
  alias Conformance.Client.Channels

  # Stands in for `GRPC.Stub.connect/2`: counts connects and answers with what `reply` says.
  # `ready` stands in for `GRPC.Client.Connection.await_ready/2`.
  defp start_channels(reply \\ fn n -> {:ok, {:channel, n}} end, ready \\ fn _ -> :ok end) do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    connect = fn addr, opts ->
      n = Agent.get_and_update(counter, &{&1 + 1, &1 + 1})
      send(opts[:test], {:connected, addr, n})
      reply.(n)
    end

    {:ok, channels} = Channels.start_link(connect: connect, ready: ready)
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
