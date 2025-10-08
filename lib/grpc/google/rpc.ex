defmodule GRPC.Google.Rpc do
  @moduledoc false

  @spec encode_status(Google.Rpc.Status.t()) :: String.t()
  def encode_status(%Google.Rpc.Status{} = status) do
    status
    |> Google.Rpc.Status.encode()
    |> Base.encode64(padding: true)
  end

  @spec decode_status(String.t()) :: {:ok, Google.Rpc.Status.t()} | {:error, term()}
  def decode_status(encoded_details_bin) when is_binary(encoded_details_bin) do
    {:ok,
     encoded_details_bin
     |> Base.decode64!(padding: true)
     |> Google.Rpc.Status.decode()}
  rescue
    e -> {:error, e}
  end
end
