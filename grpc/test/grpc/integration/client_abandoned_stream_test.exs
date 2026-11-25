defmodule GRPC.Integration.ClientAbandonedStreamTest do
  use GRPC.Integration.TestCase, async: false

  alias GRPC.Client.Adapters.{Gun, Mint}

  @response_processes [
    {GRPC.Client.Adapters.Mint.StreamResponseProcess, :init, 1},
    {GRPC.Client.Adapters.Gun.StreamResponseProcess, :init, 1},
    {GRPC.Client.Adapters.Gun.ReplyReader, :init, 1}
  ]

  defmodule OpenServer do
    use GRPC.Server, service: Routeguide.RouteGuide.Service, connect: true

    def list_features(_rect, stream) do
      send(:persistent_term.get({__MODULE__, :test}), {:handler, self()})
      feature = %Routeguide.Feature{name: "x"}

      GRPC.Server.send_reply(stream, feature)
      GRPC.Server.send_reply(stream, feature)
      Process.sleep(:infinity)
    end
  end

  defp response_processes do
    for pid <- Process.list(),
        {:dictionary, dict} <- [Process.info(pid, :dictionary)],
        dict[:"$initial_call"] in @response_processes,
        into: MapSet.new(),
        do: pid
  end

  defp links do
    {:links, links} = Process.info(self(), :links)
    links |> Enum.filter(&is_pid/1) |> MapSet.new()
  end

  # What the client runs for a call started by the calling process: the response processes
  # and anything linked to the caller that was not before.
  defp snapshot, do: {response_processes(), links()}

  defp opened({processes, links}) do
    MapSet.union(
      MapSet.difference(response_processes(), processes),
      MapSet.difference(links(), links)
    )
  end

  defp connect(port, adapter, protocol) do
    {:ok, channel} =
      GRPC.Stub.connect("localhost:#{port}",
        adapter: adapter,
        protocol: protocol,
        adapter_opts: [protocols: [:http2]]
      )

    on_exit(fn ->
      try do
        GRPC.Stub.disconnect(channel)
      catch
        _, _ -> :ok
      end
    end)

    channel
  end

  defp list(channel),
    do: Routeguide.RouteGuide.Stub.list_features(channel, %Routeguide.Rectangle{})

  # The handler of the stream on the server ends once the client reset the stream, and
  # the processes the client opened for it are gone.
  defp assert_released(opened) do
    assert_receive {:handler, handler}, 5_000
    handler_ref = Process.monitor(handler)
    refs = for pid <- opened, do: {pid, Process.monitor(pid)}

    assert_receive {:DOWN, ^handler_ref, :process, ^handler, _reason}, 5_000

    for {pid, ref} <- refs do
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 5_000
    end
  end

  for adapter <- [Mint, Gun], protocol <- [:grpc, :connect] do
    describe "with the #{inspect(adapter)} adapter over #{protocol}" do
      @describetag adapter: adapter, protocol: protocol

      setup do
        :persistent_term.put({OpenServer, :test}, self())
        on_exit(fn -> :persistent_term.erase({OpenServer, :test}) end)
      end

      test "taking a part of a server stream resets the stream", ctx do
        run_server(OpenServer, fn port ->
          channel = connect(port, ctx.adapter, ctx.protocol)
          before = snapshot()

          {:ok, replies} = list(channel)
          opened = opened(before)
          assert [{:ok, %Routeguide.Feature{}}] = Enum.take(replies, 1)

          assert_released(opened)
        end)
      end

      test "a caller that exits without reading the stream resets the stream", ctx do
        run_server(OpenServer, fn port ->
          channel = connect(port, ctx.adapter, ctx.protocol)
          test = self()

          {pid, ref} =
            spawn_monitor(fn ->
              before = snapshot()
              {:ok, _replies} = list(channel)
              send(test, {:opened, opened(before)})
            end)

          assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 5_000
          assert_receive {:opened, opened}

          assert_released(opened)
        end)
      end
    end
  end
end
