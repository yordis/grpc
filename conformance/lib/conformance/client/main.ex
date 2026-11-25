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

  def run(adapter) do
    # Treat stdin/stdout as raw bytes: the default device re-encodes as UTF-8.
    :ok = :io.setopts(:standard_io, [:binary, encoding: :latin1])
    {:ok, out} = Agent.start_link(fn -> nil end)

    loop(adapter, out, 0)
    System.halt(0)
  end

  defp loop(adapter, out, in_flight) do
    case read_request() do
      :eof ->
        wait_for(0, in_flight)

      request ->
        in_flight = if in_flight >= @max_in_flight, do: wait_for(@max_in_flight - 1, in_flight), else: in_flight
        parent = self()

        spawn(fn ->
          write(out, execute(request, adapter))
          send(parent, :done)
        end)

        loop(adapter, out, in_flight + 1)
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
          result: {:error, %ClientErrorResult{message: "call did not finish within #{@call_deadline_ms} ms"}}
        }
    end
  end

  defp run_call(%ClientCompatRequest{test_name: name} = request, adapter) do
    Conformance.Client.Call.run(request, adapter)
  rescue
    error ->
      %ClientCompatResponse{
        test_name: name,
        result: {:error, %ClientErrorResult{message: Exception.format(:error, error, __STACKTRACE__)}}
      }
  catch
    kind, reason ->
      %ClientCompatResponse{
        test_name: name,
        result: {:error, %ClientErrorResult{message: "#{kind}: #{inspect(reason)}"}}
      }
  end

  defp read_request do
    case IO.binread(:stdio, 4) do
      :eof ->
        :eof

      <<size::32-big>> ->
        ClientCompatRequest.decode(read_exactly(size))

      other ->
        raise "short read from stdin: #{inspect(other)}"
    end
  end

  defp read_exactly(0), do: <<>>

  defp read_exactly(n) do
    case IO.binread(:stdio, n) do
      data when is_binary(data) and byte_size(data) == n -> data
      other -> raise "short read from stdin: #{inspect(other)}"
    end
  end

  # One writer at a time, so concurrent results never interleave.
  defp write(out, %ClientCompatResponse{} = response) do
    bin = ClientCompatResponse.encode(response)

    Agent.get(out, fn _ -> IO.binwrite(:stdio, <<byte_size(bin)::32-big, bin::binary>>) end, :infinity)
  end
end
