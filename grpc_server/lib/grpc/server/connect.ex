defmodule GRPC.Server.Connect do
  @moduledoc false
  # The parts of the Connect protocol (https://connectrpc.com/docs/protocol) that do not
  # depend on the HTTP server: content types, error codes and the error and end-of-stream
  # JSON.

  alias GRPC.RPCError

  @type_prefix "type.googleapis.com/"

  @code_names ~w(
    ok canceled unknown invalid_argument deadline_exceeded not_found already_exists
    permission_denied resource_exhausted failed_precondition aborted out_of_range
    unimplemented internal unavailable data_loss unauthenticated
  )

  # The HTTP status of an error, by gRPC status code.
  # https://connectrpc.com/docs/protocol#error-codes
  @http_statuses %{
    1 => 499,
    2 => 500,
    3 => 400,
    4 => 504,
    5 => 404,
    6 => 409,
    7 => 403,
    8 => 429,
    9 => 400,
    10 => 409,
    11 => 400,
    12 => 501,
    13 => 500,
    14 => 503,
    15 => 500,
    16 => 401
  }

  @doc """
  The Connect name of a gRPC status code, such as `"not_found"` for 5.
  """
  def code_name(status) when status in 0..16, do: Enum.at(@code_names, status)
  def code_name(_status), do: "unknown"

  @doc """
  The HTTP status that a unary response with this gRPC status code carries.
  """
  def http_status(status), do: Map.get(@http_statuses, status, 500)

  @doc """
  The status line of a unary response with this gRPC status code, as cowboy takes it.

  Cowboy has no reason phrase for 499, so HTTP/1.1 would fail to write it as a bare integer.
  """
  def status_line(status) do
    case http_status(status) do
      499 -> "499 Client Closed Request"
      http_status -> http_status
    end
  end

  @doc """
  Reads a request or response content type.

  Gives `{:unary, codec_name}` for `application/proto` and `application/json`,
  `{:stream, codec_name}` for `application/connect+proto` and `application/connect+json`,
  and `:error` for anything else. Parameters such as `charset` are ignored.
  """
  def parse_content_type(content_type) when is_binary(content_type) do
    case content_type |> media_type() |> String.downcase() do
      "application/proto" -> {:unary, "proto"}
      "application/json" -> {:unary, "json"}
      "application/connect+" <> codec when codec in ["proto", "json"] -> {:stream, codec}
      _ -> :error
    end
  end

  def parse_content_type(_content_type), do: :error

  defp media_type(content_type) do
    content_type |> String.split(";", parts: 2) |> hd() |> String.trim()
  end

  @doc """
  Whether the request of a stream uses the enveloped, streaming form of the protocol.
  """
  def streaming?(%{http_request_headers: headers}) do
    match?({:stream, _}, parse_content_type(Map.get(headers, "content-type")))
  end

  @doc """
  The compressor for the response: the first of the codings the client accepts that the
  server has, or `nil`. A stream names them in `Connect-Accept-Encoding`, a unary call in
  `Accept-Encoding`.
  """
  def response_compressor(%{http_request_headers: headers, server: server} = stream) do
    header = if streaming?(stream), do: "connect-accept-encoding", else: "accept-encoding"

    accepted =
      headers
      |> Map.get(header, "")
      |> String.split(",")
      |> Enum.map(&(&1 |> String.split(";") |> hd() |> String.trim()))

    compressors = server.__meta__(:compressors)

    Enum.find_value(accepted, fn name -> Enum.find(compressors, &(&1.name() == name)) end)
  end

  @doc """
  The last message of a stream: the error, if any, and the trailers as metadata.
  """
  def end_stream_body(error, trailers) do
    metadata =
      Map.new(trailers, fn {name, value} -> {name, List.wrap(value)} end)

    %{}
    |> then(fn map -> if error, do: Map.put(map, "error", error_map(error)), else: map end)
    |> then(fn map -> if metadata == %{}, do: map, else: Map.put(map, "metadata", metadata) end)
    |> Jason.encode_to_iodata!()
  end

  @doc """
  The content type of a response.
  """
  def content_type(streaming?, codec_name)
  def content_type(false, codec_name), do: "application/#{codec_name}"
  def content_type(true, codec_name), do: "application/connect+#{codec_name}"

  @doc """
  The body of the response to a failed unary call.
  """
  def error_body(%RPCError{} = error) do
    error |> error_map() |> Jason.encode_to_iodata!()
  end

  @doc """
  The JSON for an error, in a unary response body and in the end of a stream.
  """
  def error_map(%RPCError{status: status, message: message, details: details}) do
    %{"code" => code_name(status)}
    |> put_present("message", message)
    |> put_present("details", Enum.map(details || [], &detail/1))
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, _key, ""), do: map
  defp put_present(map, _key, []), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp detail(%{type_url: type_url, value: value}) do
    %{
      "type" => String.replace_prefix(type_url, @type_prefix, ""),
      "value" => Base.encode64(value, padding: false)
    }
  end
end
