defmodule Conformance.Client do
  @moduledoc false

  @doc "The client adapter selected by `bin/client --adapter`."
  def adapter do
    case System.get_env("CONFORMANCE_CLIENT_ADAPTER", "mint") do
      "mint" -> GRPC.Client.Adapters.Mint
      "gun" -> GRPC.Client.Adapters.Gun
      other -> raise "unknown adapter: #{other}"
    end
  end
end
