defmodule GRPC.Client.HTTPVersions do
  @moduledoc false

  # The HTTP versions a client adapter speaks, and how it picks one. The Mint and the Gun
  # adapters share these rules, so a channel behaves the same with either.
  #
  # The `:grpc` protocol runs on HTTP/2 only. Connect and gRPC-Web run on either version,
  # `:protocols` in the adapter options lists the ones to allow, from `:http1` and `:http2`.
  #
  #   * With TLS, the versions are negotiated with ALPN. The default allows both.
  #   * Without TLS there is no negotiation, the client has to pick. It speaks HTTP/2 with
  #     prior knowledge (h2c), as a gRPC client does, unless `:protocols` is `[:http1]`.
  #     A list with both versions is HTTP/2: HTTP/1.1 is a deliberate choice, not a fallback.

  @versions [:http1, :http2]

  @type version :: :http1 | :http2

  @spec validate(atom(), keyword()) :: :ok | {:error, String.t()}
  def validate(protocol, adapter_opts) do
    case Keyword.fetch(adapter_opts, :protocols) do
      :error -> :ok
      {:ok, protocols} -> validate_protocols(protocol, protocols)
    end
  end

  defp validate_protocols(:grpc, [:http2]), do: :ok

  defp validate_protocols(:grpc, protocols) do
    {:error,
     "the :protocols adapter option is for protocol: :connect and protocol: :grpc_web, " <>
       "protocol: :grpc runs on HTTP/2 only, got: #{inspect(protocols)}"}
  end

  defp validate_protocols(_protocol, protocols) do
    if is_list(protocols) and protocols != [] and Enum.all?(protocols, &(&1 in @versions)) and
         protocols == Enum.uniq(protocols) do
      :ok
    else
      {:error,
       "the :protocols adapter option must be a non-empty list without duplicates, with " <>
         ":http1 and :http2 as the only entries, got: #{inspect(protocols)}"}
    end
  end

  @doc """
  The versions to offer for a channel, in order of preference.
  """
  @spec select(atom(), [version()] | nil, :tcp | :tls) :: [version()]
  def select(:grpc, _protocols, _transport), do: [:http2]
  def select(_protocol, nil, transport), do: select_for(@versions, transport)
  def select(_protocol, protocols, transport), do: select_for(protocols, transport)

  defp select_for(protocols, :tls), do: protocols
  defp select_for([:http1], :tcp), do: [:http1]
  defp select_for(_protocols, :tcp), do: [:http2]
end
