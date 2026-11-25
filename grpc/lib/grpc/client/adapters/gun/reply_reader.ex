if Code.ensure_loaded?(:gun) do
  defmodule GRPC.Client.Adapters.Gun.ReplyReader do
    @moduledoc false

    # Holds the state of reading the replies of a streaming Connect or gRPC-Web call, so that
    # however many times the caller enumerates them the response is read once. It ends with
    # the process that started it, whatever the reason: a link does not carry a normal exit.

    use GenServer

    def start(state), do: GenServer.start(__MODULE__, {state, self()})

    @doc "Runs `fun` on the state, which returns `{result, new_state}`."
    def get_and_update(reader, fun), do: GenServer.call(reader, {:get_and_update, fun}, :infinity)

    def stop(reader), do: GenServer.stop(reader, :normal, :infinity)

    @impl true
    def init({state, owner}) do
      Process.monitor(owner)
      {:ok, state}
    end

    @impl true
    def handle_call({:get_and_update, fun}, _from, state) do
      {result, state} = fun.(state)
      {:reply, result, state}
    end

    @impl true
    def handle_info({:DOWN, _ref, :process, _owner, _reason}, state), do: {:stop, :normal, state}
  end
end
