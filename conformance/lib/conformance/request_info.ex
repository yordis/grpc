defmodule Conformance.RequestInfo do
  @moduledoc false

  alias Connectrpc.Conformance.V1.{ConformancePayload, Header}

  @type_prefix "type.googleapis.com/"

  def build(stream, requests) do
    %ConformancePayload.RequestInfo{
      request_headers: request_headers(stream),
      timeout_ms: GRPC.Server.Stream.timeout_ms(stream),
      requests: requests
    }
  end

  def to_any(%mod{} = message), do: pack(message, mod)
  def pack(%mod{} = message), do: pack(message, mod)

  defp pack(message, mod) do
    %Google.Protobuf.Any{
      type_url: @type_prefix <> mod.full_name(),
      value: mod.encode(message)
    }
  end

  defp request_headers(stream) do
    stream
    |> GRPC.Stream.get_headers()
    |> Enum.reject(fn {name, _} -> String.starts_with?(name, ":") end)
    |> Enum.sort()
    |> Enum.map(fn {name, value} -> %Header{name: name, value: [to_string(value)]} end)
  end
end
