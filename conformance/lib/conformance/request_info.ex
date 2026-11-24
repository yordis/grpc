defmodule Conformance.RequestInfo do
  @moduledoc false

  alias Connectrpc.Conformance.V1.{ConformancePayload, Header}

  @type_prefix "type.googleapis.com/"

  def build(stream, requests) do
    %ConformancePayload.RequestInfo{
      request_headers: request_headers(stream),
      timeout_ms: timeout_ms(stream),
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

  defp timeout_ms(stream) do
    headers = GRPC.Stream.get_headers(stream)

    case headers do
      %{"grpc-timeout" => value} -> parse_grpc_timeout(value)
      %{"connect-timeout-ms" => value} -> parse_int(value)
      _ -> nil
    end
  end

  defp parse_grpc_timeout(value) do
    case Integer.parse(value) do
      {n, "H"} -> n * 3_600_000
      {n, "M"} -> n * 60_000
      {n, "S"} -> n * 1000
      {n, "m"} -> n
      {n, "u"} -> div(n, 1000)
      {n, "n"} -> div(n, 1_000_000)
      _ -> nil
    end
  end

  defp parse_int(value) do
    case Integer.parse(value) do
      {n, ""} -> n
      _ -> nil
    end
  end
end
