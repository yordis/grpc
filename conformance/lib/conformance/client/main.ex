defmodule Conformance.Client.Main do
  @moduledoc """
  Implements the runner protocol for a client under test: reads size-delimited
  `ClientCompatRequest` messages from stdin until EOF, runs each one concurrently
  and writes size-delimited `ClientCompatResponse` messages to stdout.
  """

  alias Connectrpc.Conformance.V1.{ClientCompatRequest, ClientCompatResponse, ClientErrorResult}

  @max_in_flight 32
  # A call the library never finishes must fail that one case, not stall every case behind it.
  @call_deadline_ms 25_000

  @doc """
  The most cases that run at once.
  """
  def max_in_flight, do: @max_in_flight

  def run(adapter) do
    {:ok, out} = Agent.start_link(fn -> nil end)
    {:ok, _} = Conformance.Client.Channels.start_link(name: Conformance.Client.Channels)

    loop(Conformance.Protocol.open_input(), adapter, out, 0)
    System.halt(0)
  end

  defp loop(input, adapter, out, in_flight) do
    case Conformance.Protocol.read(input) do
      :eof ->
        wait_for(0, in_flight)

      message ->
        request = ClientCompatRequest.decode(message)

        in_flight =
          if in_flight >= @max_in_flight,
            do: wait_for(@max_in_flight - 1, in_flight),
            else: in_flight

        parent = self()

        spawn(fn ->
          write(out, execute(request, adapter))
          send(parent, :done)
        end)

        loop(input, adapter, out, in_flight + 1)
    end
  end

  defp wait_for(target, in_flight) when in_flight <= target, do: in_flight

  defp wait_for(target, in_flight) do
    receive do
      :done -> wait_for(target, in_flight - 1)
    end
  end

  defp execute(%ClientCompatRequest{test_name: name} = request, adapter) do
    task = Task.async(fn -> run_call(request, adapter) end)

    case Task.yield(task, @call_deadline_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, response} ->
        response

      _ ->
        %ClientCompatResponse{
          test_name: name,
          result:
            {:error,
             %ClientErrorResult{message: "call did not finish within #{@call_deadline_ms} ms"}}
        }
    end
  end

  defp run_call(%ClientCompatRequest{test_name: name} = request, adapter) do
    Conformance.Client.Call.run(request, adapter)
  rescue
    error ->
      %ClientCompatResponse{
        test_name: name,
        result:
          {:error, %ClientErrorResult{message: Exception.format(:error, error, __STACKTRACE__)}}
      }
  catch
    kind, reason ->
      %ClientCompatResponse{
        test_name: name,
        result: {:error, %ClientErrorResult{message: "#{kind}: #{inspect(reason)}"}}
      }
  end

  # One writer at a time, so concurrent results never interleave.
  defp write(out, %ClientCompatResponse{} = response) do
    bin = ClientCompatResponse.encode(response)

    Agent.get(out, fn _ -> Conformance.Protocol.write(bin) end, :infinity)
  end
end
