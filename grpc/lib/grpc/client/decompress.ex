defmodule GRPC.Client.Decompress do
  @moduledoc false

  # Decompresses a reply payload without letting a bad payload kill the caller.
  # A corrupt payload makes the compressor raise (`:zlib` raises `:data_error`), and a payload over
  # the receive limit makes it raise `GRPC.RPCError`. Both come back as an error tuple.

  @spec run(module(), binary()) :: {:ok, binary()} | {:error, GRPC.RPCError.t()}
  def run(compressor, payload) do
    {:ok, compressor.decompress(payload)}
  rescue
    error in GRPC.RPCError ->
      {:error, error}

    _ ->
      {:error,
       GRPC.RPCError.exception(GRPC.Status.internal(), "Message could not be decompressed.")}
  end

  # Takes the next message off `buffer`. A message over `limit` or a payload that does not
  # decompress is an error, never a raise.
  def get_message(buffer, compressor, limit) do
    with :ok <- GRPC.Client.MessageLimit.check_prefix(buffer, limit) do
      case GRPC.Message.get_message(buffer, compressor, max_message_length: limit) do
        {{1, _message}, _rest} when is_nil(compressor) ->
          {:error,
           GRPC.RPCError.exception(
             status: :internal,
             message: "Compressed flag is set, but not specified in headers."
           )}

        other ->
          other
      end
    end
  rescue
    error in GRPC.RPCError ->
      {:error, error}

    _ ->
      {:error,
       GRPC.RPCError.exception(status: :internal, message: "Message could not be decompressed.")}
  end
end
