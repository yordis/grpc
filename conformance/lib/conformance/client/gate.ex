defmodule Conformance.Client.Gate do
  @moduledoc """
  Coordinates requests that change the process-wide receive limit.

  The library bounds a received message through the `:max_message_length`
  application setting, which cannot be set per call. A request with a receive
  limit therefore runs alone, with the setting changed. Every other request runs
  concurrently with the others while the setting is at its default.
  """
  use GenServer

  def start_link(_opts \\ []), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc """
  Runs `fun` while holding the gate. A non-zero `limit` runs it exclusively.

  The gate releases on its own when the calling process exits, so a call that is
  killed for exceeding its deadline cannot keep the gate closed.
  """
  def run(limit, fun) do
    mode = if limit == 0, do: :shared, else: :exclusive
    :ok = GenServer.call(__MODULE__, {:acquire, mode, limit}, :infinity)
    fun.()
  end

  @impl true
  def init(nil), do: {:ok, %{shared: 0, exclusive: false, holders: %{}, queue: :queue.new()}}

  @impl true
  def handle_call({:acquire, mode, limit}, {pid, _} = from, state) do
    {:noreply, drain(%{state | queue: :queue.in({mode, limit, pid, from}, state.queue)})}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.pop(state.holders, ref) do
      {nil, _} ->
        {:noreply, state}

      {:shared, holders} ->
        {:noreply, drain(%{state | holders: holders, shared: state.shared - 1})}

      {:exclusive, holders} ->
        Application.delete_env(:grpc, :max_message_length)
        {:noreply, drain(%{state | holders: holders, exclusive: false})}
    end
  end

  defp drain(state) do
    case :queue.peek(state.queue) do
      {:value, {:shared, _limit, pid, from}} when not state.exclusive ->
        ref = Process.monitor(pid)
        GenServer.reply(from, :ok)

        drain(%{
          state
          | shared: state.shared + 1,
            holders: Map.put(state.holders, ref, :shared),
            queue: :queue.drop(state.queue)
        })

      {:value, {:exclusive, limit, pid, from}} when not state.exclusive and state.shared == 0 ->
        ref = Process.monitor(pid)
        Application.put_env(:grpc, :max_message_length, limit)
        GenServer.reply(from, :ok)

        drain(%{
          state
          | exclusive: true,
            holders: Map.put(state.holders, ref, :exclusive),
            queue: :queue.drop(state.queue)
        })

      _ ->
        state
    end
  end
end
