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

  import Bitwise

  alias GRPC.Client.Connect
  alias GRPC.Transport.HTTP2

  defstruct [
    :kind,
    :codec,
    :response_mod,
    :status,
    :headers,
    compressors: [],
    ended: false,
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
    {response, [{:headers, response_headers(response, headers)}], :ok}
  end

  def consume(response, {:headers, _trailers}), do: {response, [], :ok}

  def consume(%{ended: true} = response, {:data, _data}), do: {response, [], :ok}

  def consume(%{kind: :stream, status: 200} = response, {:data, data}),
    do: drain(%{response | body: response.body <> data}, [])

  def consume(response, {:data, data}), do: {%{response | body: response.body <> data}, [], :ok}

  def consume(%{status: status} = response, :done) when status != 200 do
    items = [{:trailers, trailers(response.headers)}, {:error, unary_error(response)}]
    {response, items, :ok}
  end

  def consume(%{kind: :stream, ended: true} = response, :done), do: {response, [], :ok}

  def consume(%{kind: :stream} = response, :done) do
    message =
      if response.body == <<>>,
        do: "The response ended without the end of stream message",
        else: "The response ended in the middle of a message"

    error = GRPC.RPCError.exception(GRPC.Status.internal(), message)
    {response, [{:error, error}], :ok}
  end

  def consume(%{kind: :unary, status: 200} = response, :done) do
    trailers = {:trailers, trailers(response.headers)}

    with :ok <- check_content_type(response),
         {:ok, body} <- decompress(response, "content-encoding", response.body),
         {:ok, reply} <-
           GRPC.Client.ReplyDecoder.decode(response.codec, body, response.response_mod) do
      {response, [{:ok, reply}, trailers], :ok}
    else
      {:error, error} -> {response, [trailers, {:error, error}], :ok}
    end
  end

  # A reply that is not `application/<something>` is not from a Connect server. A codec
  # that is not the expected one fails to decode further down.
  defp check_content_type(response) do
    case header_value(response.headers, "content-type") do
      "application/" <> _ ->
        :ok

      content_type ->
        {:error,
         GRPC.RPCError.exception(
           GRPC.Status.unknown(),
           "Invalid content-type #{inspect(content_type)} in the response"
         )}
    end
  end

  # The envelopes of a stream: a flag, the length of the payload, the payload.
  # Bit 0 of the flag says the payload is compressed, bit 1 that it is the end of the
  # stream.
  defp drain(response, items) do
    with :ok <- GRPC.Client.MessageLimit.check_prefix(response.body),
         <<flag::8, length::big-32, rest::binary>> when byte_size(rest) >= length <-
           response.body do
      <<payload::binary-size(^length), rest::binary>> = rest
      response = %{response | body: rest}

      case envelope(response, flag, payload) do
        {:message, reply} ->
          drain(response, [{:ok, reply} | items])

        {:end_stream, end_items} ->
          {%{response | ended: true}, Enum.reverse(items, end_items), :ok}

        {:error, error} ->
          {%{response | ended: true}, Enum.reverse(items, [{:error, error}]), :cancel}
      end
    else
      {:error, error} ->
        {%{response | ended: true}, Enum.reverse(items, [{:error, error}]), :cancel}

      _incomplete ->
        {response, Enum.reverse(items), :ok}
    end
  end

  defp envelope(_response, flag, _payload) when (flag &&& 0xFC) != 0 do
    {:error, GRPC.RPCError.exception(GRPC.Status.internal(), "Invalid envelope flags #{flag}")}
  end

  defp envelope(response, flag, payload) do
    with {:ok, payload} <- decompress_envelope(response, flag, payload) do
      if (flag &&& 2) == 2 do
        end_stream(response, payload)
      else
        case GRPC.Client.ReplyDecoder.decode(response.codec, payload, response.response_mod) do
          {:ok, reply} -> {:message, reply}
          {:error, error} -> {:error, error}
        end
      end
    end
  end

  defp decompress_envelope(response, flag, payload) when (flag &&& 1) == 1 do
    case header_value(response.headers, "connect-content-encoding") do
      encoding when encoding in [nil, "", "identity"] ->
        {:error,
         GRPC.RPCError.exception(
           GRPC.Status.internal(),
           "Compressed flag is set, but the response has no connect-content-encoding"
         )}

      _encoding ->
        decompress(response, "connect-content-encoding", payload)
    end
  end

  defp decompress_envelope(_response, _flag, payload), do: {:ok, payload}

  # The last envelope: the error of the call, if any, and the trailing metadata.
  defp end_stream(response, payload) do
    case Jason.decode(payload) do
      {:ok, %{} = json} ->
        trailers = end_metadata(json["metadata"])
        items = [{:trailers, trailers}]

        case json["error"] do
          nil ->
            {:end_stream, items}

          %{} = error_json ->
            error = error(error_json, GRPC.Status.unknown())

            error = %{
              error
              | headers: response_headers(response, response.headers),
                trailers: trailers
            }

            {:end_stream, items ++ [{:error, error}]}

          _ ->
            {:error, bad_end_stream()}
        end

      _ ->
        {:error, bad_end_stream()}
    end
  end

  defp bad_end_stream,
    do: GRPC.RPCError.exception(GRPC.Status.internal(), "Invalid end of stream message")

  defp end_metadata(%{} = metadata) do
    metadata
    |> Enum.flat_map(fn {key, values} ->
      for value <- List.wrap(values), do: {key, to_string(value)}
    end)
    |> HTTP2.decode_headers()
  end

  defp end_metadata(_metadata), do: %{}

  # The error of a failed response is a JSON body, possibly compressed. Without one, the HTTP
  # status says what went wrong, and where the JSON has no usable code it does too.
  defp unary_error(%{status: status} = response) do
    fallback = HTTP2.status_from_http(status)

    error =
      with {:ok, body} <- decompress(response, "content-encoding", response.body),
           {:ok, %{} = json} <- Jason.decode(body) do
        error(json, fallback)
      else
        _ -> GRPC.RPCError.exception(fallback, "HTTP status #{status}")
      end

    %{
      error
      | headers: response_headers(response, response.headers || []),
        trailers: trailers(response.headers || [])
    }
  end

  # The JSON of an error, in the body of a unary response and in the end of a stream.
  defp error(json, fallback) do
    status =
      case code_status(json["code"]) do
        {:ok, status} -> status
        :error -> fallback
      end

    %GRPC.RPCError{status: status, message: json["message"], details: details(json["details"])}
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

  defp response_headers(%{kind: :unary}, headers) do
    headers
    |> Enum.reject(fn {name, _} -> String.starts_with?(name, "trailer-") end)
    |> HTTP2.decode_headers()
  end

  defp response_headers(_response, headers), do: HTTP2.decode_headers(headers)

  defp trailers(headers) do
    headers
    |> Enum.filter(fn {name, _} -> String.starts_with?(name, "trailer-") end)
    |> Enum.map(fn {"trailer-" <> name, value} -> {name, value} end)
    |> HTTP2.decode_headers()
  end
end
