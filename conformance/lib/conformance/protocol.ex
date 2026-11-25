defmodule Conformance.Protocol do
  @moduledoc """
  Writes the runner's length-prefixed messages.

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
end
