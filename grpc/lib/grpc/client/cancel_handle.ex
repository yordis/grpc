defmodule GRPC.Client.CancelHandle do
  @moduledoc """
  A handle that cancels a unary or server-streaming call from any process.

  Make one with `GRPC.Stub.new_cancel_handle/0`, pass it to the call with the `:cancel`
  option, and cancel the call with `GRPC.Stub.cancel/1`. A handle is for one call.
  """

  @table __MODULE__

  @enforce_keys [:ref, :flag]
  defstruct [:ref, :flag]

  @type t :: %__MODULE__{ref: reference, flag: :atomics.atomics_ref()}

  @doc false
  def table, do: @table

  @doc false
  def new, do: %__MODULE__{ref: make_ref(), flag: :atomics.new(1, [])}

  @doc false
  def canceled?(%__MODULE__{flag: flag}), do: :atomics.get(flag, 1) == 1

  @doc false
  # Remembers the stream of the call, so a cancel can reach it. Returns `:canceled` when
  # the handle was cancelled before, or while, the stream was registered.
  def register(%__MODULE__{ref: ref} = handle, stream) do
    :ets.insert(@table, {ref, stream})
    if canceled?(handle), do: :canceled, else: :ok
  end

  @doc false
  def unregister(%__MODULE__{ref: ref}) do
    :ets.delete(@table, ref)
    :ok
  end

  @doc false
  # The flag is set before the lookup and the stream is registered before the flag is
  # read, so a cancel and a registration at the same time are seen by at least one side.
  def cancel(%__MODULE__{ref: ref, flag: flag}) do
    :atomics.put(flag, 1, 1)

    case :ets.lookup(@table, ref) do
      [{^ref, stream}] -> reset(stream)
      [] -> :ok
    end
  end

  @doc false
  # Resets the stream of a call on the adapter. A call that is over, or a connection that
  # is gone, has nothing left to reset.
  def reset(%{channel: %{adapter: adapter}} = stream) do
    adapter.cancel(stream)
    :ok
  catch
    :exit, _reason -> :ok
  end

  defmodule Table do
    @moduledoc false
    # Owns the table of the streams of the calls that have a handle.
    use GenServer

    def start_link(_opts), do: GenServer.start_link(__MODULE__, nil)

    @impl true
    def init(nil) do
      :ets.new(GRPC.Client.CancelHandle.table(), [:named_table, :public, :set])
      {:ok, nil}
    end
  end
end
