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
    compressors: [],
    body: <<>>
  ]

  def new(stream) do
    %__MODULE__{
      kind: Connect.kind(stream),
      codec: stream.codec,
      response_mod: stream.response_mod,
      compressors:
        Enum.uniq(Enum.reject([stream.compressor | stream.accepted_compressors], &is_nil/1))
    }
  end

  def consume(response, {:status, status}), do: {%{response | status: status}, [], :ok}

  def consume(%{headers: nil} = response, {:headers, headers}) do
    response = %{response | headers: headers}
    {response, [{:headers, response_headers(headers)}], :ok}
  end

  def consume(response, {:headers, _trailers}), do: {response, [], :ok}

  def consume(response, {:data, data}), do: {%{response | body: response.body <> data}, [], :ok}

  def consume(%{kind: :unary, status: 200} = response, :done) do
    trailers = {:trailers, trailers(response.headers)}

    with {:ok, body} <- decompress(response, "content-encoding", response.body),
         {:ok, reply} <-
           GRPC.Client.ReplyDecoder.decode(response.codec, body, response.response_mod) do
      {response, [{:ok, reply}, trailers], :ok}
    else
      {:error, error} -> {response, [trailers, {:error, error}], :ok}
    end
  end

  def consume(%{kind: :unary} = response, :done) do
    items = [{:trailers, trailers(response.headers)}, {:error, unary_error(response)}]
    {response, items, :ok}
  end

  # The error of a failed unary call is a JSON body. Without one, the HTTP status says what
  # went wrong.
  defp unary_error(%{status: status, body: body}) do
    with {:ok, %{"code" => code} = json} <- Jason.decode(body),
         {:ok, grpc_status} <- code_status(code) do
      %GRPC.RPCError{
        status: grpc_status,
        message: json["message"],
        details: details(json["details"])
      }
    else
      _ ->
        GRPC.RPCError.exception(
          HTTP2.status_from_http(status),
          "HTTP status #{status}"
        )
    end
  end

  @codes ~w(
    ok canceled unknown invalid_argument deadline_exceeded not_found already_exists
    permission_denied resource_exhausted failed_precondition aborted out_of_range
    unimplemented internal unavailable data_loss unauthenticated
  )

  defp code_status(code) when is_binary(code) do
    case Enum.find_index(@codes, &(&1 == code)) do
      nil -> :error
      index -> {:ok, index}
    end
  end

  defp code_status(_code), do: :error

  defp details(details) when is_list(details) do
    for %{"type" => type, "value" => value} <- details, {:ok, bytes} <- [decode_value(value)] do
      %Google.Protobuf.Any{type_url: "type.googleapis.com/" <> type, value: bytes}
    end
  end

  defp details(_details), do: nil

  defp decode_value(value) when is_binary(value) do
    case Base.decode64(value, padding: false) do
      {:ok, _} = ok -> ok
      :error -> Base.decode64(value)
    end
  end

  defp decode_value(_value), do: :error

  # Identity, or a compressor the caller listed.
  defp decompress(response, header, body) do
    case header_value(response.headers, header) do
      encoding when encoding in [nil, "", "identity"] ->
        {:ok, body}

      encoding ->
        case Enum.find(response.compressors, &(&1.name() == encoding)) do
          nil ->
            {:error,
             GRPC.RPCError.exception(
               GRPC.Status.internal(),
               "Unsupported #{header} #{inspect(encoding)} in the response"
             )}

          compressor ->
            {:ok, compressor.decompress(body)}
        end
    end
  end

  defp header_value(headers, name) do
    Enum.find_value(headers, fn {key, value} -> if key == name, do: value end)
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
