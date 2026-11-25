defmodule GRPC.Client.Connect.Response do
  @moduledoc false
  # The response side of the Connect protocol, as a state machine that does not do any
  # I/O. An adapter feeds it the events of one HTTP response, in order:
  #
  #   * `{:status, status}`
  #   * `{:headers, headers}`, a list of `{name, value}`. The first is the response
  #     headers, any later one is trailers of the HTTP message, which Connect ignores.
  #   * `{:data, binary}`
  #   * `:done`
  #
  # `consume/2` gives back the new state, the items the response produced, in the same
  # shapes the gRPC adapters produce (`{:headers, map}`, `{:ok, message}`,
  # `{:trailers, map}`, `{:error, error}`), and `:cancel` when the request should be reset
  # because the response cannot be read any further.

  alias GRPC.Client.Connect
  alias GRPC.Transport.HTTP2

  defstruct [
    :kind,
    :codec,
    :response_mod,
    :status,
    :headers,
    body: <<>>
  ]

  def new(stream) do
    %__MODULE__{
      kind: Connect.kind(stream),
      codec: stream.codec,
      response_mod: stream.response_mod
    }
  end

  def consume(response, {:status, status}), do: {%{response | status: status}, [], :ok}

  def consume(%{headers: nil} = response, {:headers, headers}) do
    response = %{response | headers: headers}
    {response, [{:headers, response_headers(headers)}], :ok}
  end

  def consume(response, {:headers, _trailers}), do: {response, [], :ok}

  def consume(response, {:data, data}), do: {%{response | body: response.body <> data}, [], :ok}

  def consume(%{kind: :unary} = response, :done) do
    {:ok, reply} =
      GRPC.Client.ReplyDecoder.decode(response.codec, response.body, response.response_mod)

    {response, [{:ok, reply}, {:trailers, trailers(response.headers)}], :ok}
  end

  defp response_headers(headers) do
    headers
    |> Enum.reject(fn {name, _} -> String.starts_with?(name, "trailer-") end)
    |> HTTP2.decode_headers()
  end

  defp trailers(headers) do
    headers
    |> Enum.filter(fn {name, _} -> String.starts_with?(name, "trailer-") end)
    |> Enum.map(fn {"trailer-" <> name, value} -> {name, value} end)
    |> HTTP2.decode_headers()
  end
end
