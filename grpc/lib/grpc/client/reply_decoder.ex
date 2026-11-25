defmodule GRPC.Client.ReplyDecoder do
  @moduledoc false

  # A server may answer in a format the client's codec cannot read, and a codec raises
  # on bytes it does not understand. That is a failed call, not a crash of the client.
  @spec decode(module(), binary(), module()) :: {:ok, struct()} | {:error, GRPC.RPCError.t()}
  def decode(codec, message, res_mod) do
    {:ok, codec.decode(message, res_mod)}
  rescue
    exception ->
      {:error,
       GRPC.RPCError.exception(
         GRPC.Status.internal(),
         "Failed to decode the response: #{Exception.message(exception)}"
       )}
  end
end
