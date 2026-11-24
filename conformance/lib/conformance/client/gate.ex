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

  @doc "Runs `fun` while holding the gate. A non-zero `limit` runs it exclusively."
  def run(limit, fun) do
    mode = if limit == 0, do: :shared, else: :exclusive
    :ok = GenServer.call(__MODULE__, {:acquire, mode}, :infinity)

    try do
      if mode == :exclusive, do: Application.put_env(:grpc, :max_message_length, limit)
      fun.()
    after
      if mode == :exclusive, do: Application.delete_env(:grpc, :max_message_length)
      GenServer.cast(__MODULE__, {:release, mode})
    end
  end

  @impl true
  def init(nil), do: {:ok, %{shared: 0, exclusive: false, queue: :queue.new()}}

  @impl true
  def handle_call({:acquire, mode}, from, state) do
    {:noreply, drain(%{state | queue: :queue.in({mode, from}, state.queue)})}
  end

  @impl true
  def handle_cast({:release, :shared}, state), do: {:noreply, drain(%{state | shared: state.shared - 1})}
  def handle_cast({:release, :exclusive}, state), do: {:noreply, drain(%{state | exclusive: false})}

  defp drain(state) do
    case :queue.peek(state.queue) do
      {:value, {:shared, from}} when not state.exclusive ->
        GenServer.reply(from, :ok)
        drain(%{state | shared: state.shared + 1, queue: :queue.drop(state.queue)})

      {:value, {:exclusive, from}} when not state.exclusive and state.shared == 0 ->
        GenServer.reply(from, :ok)
        drain(%{state | exclusive: true, queue: :queue.drop(state.queue)})

      _ ->
        state
    end
  end
end
