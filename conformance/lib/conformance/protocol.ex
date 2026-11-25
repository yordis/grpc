defmodule Conformance.Protocol do
  @moduledoc """
  Reads and writes the runner's length-prefixed messages.

  Both directions bypass the group leader, whose device decodes UTF-8 until something sets it
  to bytes and can be set back by anything that touches its options. Messages are bytes, so
  they go through raw file handles on the standard descriptors instead.

  The runner reads its messages from stdout, so a log line or any other text there is read
  as a message size. `bin/launch` moves stdout to stderr for everything in the program and
  hands the real stdout to this module as the file descriptor named by
  `CONFORMANCE_PROTOCOL_FD`. Without it, such as in a test, messages go to stdout.
  """

  @doc "Writes `message` with its 4 byte big-endian size in front."
  @spec write(binary()) :: :ok
  def write(message) when is_binary(message) do
    frame = <<byte_size(message)::32-big, message::binary>>

    case System.get_env("CONFORMANCE_PROTOCOL_FD") do
      nil ->
        :ok = IO.binwrite(:stdio, frame)

      fd ->
        file = File.open!("/dev/fd/#{fd}", [:write, :binary, :raw])
        :ok = :file.write(file, frame)
        :ok = File.close(file)
    end
  end

  @doc "Opens standard input for `read/1`. Open it once and read from one process."
  @spec open_input() :: :file.fd()
  def open_input, do: File.open!("/dev/fd/0", [:read, :binary, :raw])

  @doc """
  Reads one message from `input`: its bytes, or `:eof` when the input ended before the first
  byte of a message. Input that ends inside a message raises.
  """
  @spec read(:file.fd()) :: binary() | :eof
  def read(input) do
    case read_exactly(input, 4) do
      :eof -> :eof
      <<size::32-big>> -> read_body(input, size)
    end
  end

  defp read_body(_input, 0), do: <<>>

  defp read_body(input, size) do
    case read_exactly(input, size) do
      :eof -> raise "stdin ended inside a message of #{size} bytes"
      data -> data
    end
  end

  # A pipe returns what it has, so keep reading until `n` bytes arrived.
  defp read_exactly(input, n, acc \\ <<>>)

  defp read_exactly(_input, 0, acc), do: acc

  defp read_exactly(input, n, acc) do
    case :file.read(input, n) do
      {:ok, data} -> read_exactly(input, n - byte_size(data), acc <> data)
      :eof when acc == <<>> -> :eof
      :eof -> raise "stdin ended after #{byte_size(acc)} of #{byte_size(acc) + n} bytes"
      {:error, reason} -> raise "cannot read stdin: #{inspect(reason)}"
    end
  end
end
