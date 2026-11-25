defmodule GRPC.Client.GrpcWeb.Response do
  @moduledoc false
  # The response side of the gRPC-Web protocol, as a state machine that does not do any
  # I/O. It takes the same events as `GRPC.Client.Connect.Response`, in order:
  #
  #   * `{:status, status}`
  #   * `{:headers, headers}`, a list of `{name, value}`. The first is the response
  #     headers, any later one is trailers of the HTTP message, which gRPC-Web does not use.
  #   * `{:data, binary}`
  #   * `:done`
  #
  # `consume/2` gives back the new state, the items the response produced (`{:headers, map}`,
  # `{:ok, message}`, `{:trailers, map}`, `{:error, error}`), and `:cancel` when the request
  # should be reset because the response cannot be read any further.
  #
  # The body is a sequence of envelopes: a flag, the length of the payload, the payload. Bit 0
  # of the flag says the payload is compressed, bit 7 that it is the trailers: the lines
  # `name: value` of the HTTP/1 header format, which carry the `grpc-status`. A response
  # that has only headers is trailers-only, and its headers carry the `grpc-status`.

  import Bitwise

  alias GRPC.Transport.HTTP2

  defstruct [
    :codec,
    :response_mod,
    :status,
    :headers,
    :compressor,
    :bad_content_type,
    compressors: [],
    ended: false,
    data_seen: false,
    body: <<>>
  ]

  def new(stream) do
    %__MODULE__{
      codec: stream.codec,
      response_mod: stream.response_mod,
      compressors:
        Enum.uniq(Enum.reject([stream.compressor | stream.accepted_compressors], &is_nil/1))
    }
  end

  def consume(response, {:status, status}), do: {%{response | status: status}, [], :ok}

  def consume(%{headers: nil, status: 200} = response, {:headers, headers}) do
    decoded = HTTP2.decode_headers(headers)

    response = %{
      response
      | headers: headers,
        compressor: compressor(response, decoded["grpc-encoding"]),
        bad_content_type: bad_content_type(decoded["content-type"])
    }

    # The headers of a trailers-only response are the trailers: they are known to be so
    # only when the response ends.
    if Map.has_key?(decoded, "grpc-status") do
      {response, [], :ok}
    else
      {response, [{:headers, decoded}], :ok}
    end
  end

  def consume(%{headers: nil} = response, {:headers, headers}),
    do: {%{response | headers: headers}, [], :ok}

  def consume(response, {:headers, _trailers}), do: {response, [], :ok}

  def consume(%{ended: true} = response, {:data, _data}), do: {response, [], :ok}

  def consume(%{status: 200, bad_content_type: nil} = response, {:data, data}),
    do: drain(%{response | body: response.body <> data, data_seen: true}, [])

  def consume(response, {:data, _data}), do: {%{response | data_seen: true}, [], :ok}

  def consume(%{status: status} = response, :done) when status != 200 do
    {response, [{:error, http_error(response)}], :ok}
  end

  def consume(%{bad_content_type: content_type} = response, :done)
      when not is_nil(content_type) do
    error =
      GRPC.RPCError.exception(
        GRPC.Status.unknown(),
        "Unexpected content-type: #{inspect(content_type)}"
      )

    {response, [{:error, %{error | headers: decoded_headers(response)}}], :ok}
  end

  def consume(%{ended: true} = response, :done), do: {response, [], :ok}

  def consume(%{data_seen: false} = response, :done) do
    decoded = decoded_headers(response)

    if Map.has_key?(decoded, "grpc-status") do
      {response, trailers_items(decoded, nil, true), :ok}
    else
      {response, [{:error, missing_status(response, <<>>)}], :ok}
    end
  end

  def consume(response, :done),
    do: {response, [{:error, missing_status(response, response.body)}], :ok}

  # The error of a response that is not a 200: the `grpc-status` when the headers have one,
  # the HTTP status otherwise.
  defp http_error(response) do
    decoded = decoded_headers(response)

    case status_error(decoded, nil) do
      {:error, error} ->
        error

      _ ->
        error =
          GRPC.RPCError.exception(
            HTTP2.status_from_http(response.status),
            "status got is #{response.status} instead of 200"
          )

        %{error | headers: decoded, trailers: %{}}
    end
  end

  # The items of the trailers of a response: the trailers when the call succeeded, the error
  # of the call otherwise.
  defp trailers_items(trailers, headers, trailers_only?) do
    case status_error(trailers, headers) do
      :ok when trailers_only? -> [{:headers, trailers}]
      :ok -> [{:trailers, trailers}]
      {:error, error} -> [{:error, error}]
    end
  end

  defp status_error(trailers, headers) do
    case parse_status(trailers["grpc-status"]) do
      nil ->
        {:error, with_metadata(missing_status(nil, <<>>), headers, trailers)}

      :error ->
        error = GRPC.RPCError.exception(GRPC.Status.internal(), "Invalid grpc-status.")
        {:error, with_metadata(error, headers, trailers)}

      0 ->
        :ok

      status ->
        error =
          GRPC.RPCError.from_grpc_status_details_bin(%{
            status: status,
            message: trailers["grpc-message"],
            encoded_details_bin: trailers["grpc-status-details-bin"]
          })

        {:error, with_metadata(error, headers, trailers)}
    end
  end

  defp parse_status(nil), do: nil

  defp parse_status(value) do
    case Integer.parse(value) do
      {status, ""} -> status
      _ -> :error
    end
  end

  defp with_metadata(error, headers, trailers), do: %{error | headers: headers, trailers: trailers}

  defp missing_status(_response, <<>>),
    do: GRPC.RPCError.exception(GRPC.Status.internal(), "Missing grpc-status in the response.")

  defp missing_status(_response, _incomplete),
    do:
      GRPC.RPCError.exception(
        GRPC.Status.internal(),
        "The response ended in the middle of a message."
      )

  # Reads every complete envelope of the body.
  defp drain(response, items) do
    with :ok <- GRPC.Client.MessageLimit.check_prefix(response.body),
         <<flag::8, length::big-32, rest::binary>> when byte_size(rest) >= length <-
           response.body do
      <<payload::binary-size(^length), rest::binary>> = rest
      response = %{response | body: rest}

      case envelope(response, flag, payload) do
        {:message, reply} ->
          drain(response, [{:ok, reply} | items])

        {:trailers, trailers_items} ->
          {%{response | ended: true}, Enum.reverse(items, trailers_items), :ok}

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

  defp envelope(_response, flag, _payload) when (flag &&& 0x7E) != 0 do
    {:error, GRPC.RPCError.exception(GRPC.Status.internal(), "Invalid envelope flags #{flag}")}
  end

  defp envelope(response, flag, payload) do
    with {:ok, payload} <- decompress(response, flag, payload) do
      if (flag &&& 0x80) == 0x80 do
        trailers = payload |> parse_trailers() |> HTTP2.decode_headers()
        {:trailers, trailers_items(trailers, decoded_headers(response), false)}
      else
        case GRPC.Client.ReplyDecoder.decode(response.codec, payload, response.response_mod) do
          {:ok, reply} -> {:message, reply}
          {:error, error} -> {:error, error}
        end
      end
    end
  rescue
    error in GRPC.RPCError -> {:error, error}
  end

  defp decompress(response, flag, payload) when (flag &&& 1) == 1 do
    case response.compressor do
      nil ->
        {:error,
         GRPC.RPCError.exception(
           GRPC.Status.internal(),
           "Compressed flag is set, but not specified in headers."
         )}

      compressor ->
        {:ok, compressor.decompress(payload)}
    end
  end

  defp decompress(_response, _flag, payload), do: {:ok, payload}

  defp parse_trailers(payload) do
    payload
    |> String.split(["\r\n", "\n"], trim: true)
    |> Enum.flat_map(fn line ->
      case String.split(line, ":", parts: 2) do
        [name, value] -> [{name |> String.trim() |> String.downcase(), String.trim(value)}]
        _ -> []
      end
    end)
  end

  defp compressor(_response, nil), do: nil

  defp compressor(response, name),
    do: Enum.find(response.compressors, &(&1.name() == name))

  defp bad_content_type(nil), do: nil
  defp bad_content_type("application/grpc-web" <> _), do: nil
  defp bad_content_type(content_type), do: content_type

  defp decoded_headers(%{headers: nil}), do: %{}
  defp decoded_headers(%{headers: headers}), do: HTTP2.decode_headers(headers)
end
