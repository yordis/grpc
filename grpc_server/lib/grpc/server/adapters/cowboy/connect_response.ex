defmodule GRPC.Server.Adapters.Cowboy.ConnectResponse do
  @moduledoc false
  # The response side of the Connect protocol for `GRPC.Server.Adapters.Cowboy.Handler`.
  # Every function takes the cowboy request and the handler state, and returns what the
  # handler's `info/3` returns, except where noted.
  #
  # A unary response is one HTTP response whose trailers are headers with the prefix
  # `trailer-`. A streaming response is a sequence of enveloped messages, closed by an
  # EndStream envelope that holds the error, if any, and the trailers as metadata.

  alias GRPC.RPCError
  alias GRPC.Server.Connect
  alias GRPC.Transport.HTTP2

  @end_stream_flag 0b10

  @doc """
  A unary reply is held until the call ends, because its trailers are sent
  as headers, ahead of the body. A message of a stream is sent at once.

  Gives `{:error, error}` when the message cannot be sent.
  """
  def stream_body(data, opts, _is_fin, req, state) do
    if Connect.streaming?(state.stream) do
      stream_message(data, opts, req, state)
    else
      {:ok, req, Map.put(state, :connect_body, data)}
    end
  end

  defp stream_message(data, opts, req, state) do
    compressor =
      if opts[:compress] == false, do: nil, else: Connect.response_compressor(state.stream)

    max_length = GRPC.Server.max_send_message_length()

    case GRPC.Message.to_data(data, compressor: compressor, max_message_length: max_length) do
      {:ok, envelope, _size} ->
        req = start_stream(req)
        :cowboy_req.stream_body(envelope, :nofin, req)
        {:ok, req, state}

      {:error, message} ->
        {:error,
         RPCError.exception(
           status: :resource_exhausted,
           message: "#{message}, the limit is #{max_length} bytes"
         )}
    end
  end

  # Starts the response of a stream, with the headers set so far.
  defp start_stream(%{has_sent_resp: _} = req), do: req
  defp start_stream(req), do: :cowboy_req.stream_reply(200, req)

  @doc """
  Handlers send headers before they reply. A unary response sends its headers with its body.
  """
  def stream_reply(_status, headers, req, state) do
    req = :cowboy_req.set_resp_headers(headers, req)

    if Connect.streaming?(state.stream) do
      {:ok, start_stream(req), Map.put(state, :custom_resp_headers?, true)}
    else
      {:ok, req, Map.put(state, :custom_resp_headers?, true)}
    end
  end

  @doc """
  The end of a successful call. A unary call sends the held reply, with the trailers as
  headers. A stream sends the EndStream envelope.
  """
  def stream_trailers(req, state) do
    if Connect.streaming?(state.stream) do
      req = start_stream(req)
      :cowboy_req.stream_body(end_stream(nil, state), :fin, req)
      {:ok, req, state}
    else
      {headers, body} =
        compress(state, trailer_headers(state), Map.get(state, :connect_body, ""))

      req = :cowboy_req.reply(200, headers, body, req)
      {:ok, req, state}
    end
  end

  # Compresses a unary response with the codec the client accepts.
  defp compress(state, headers, body) do
    compressor = Connect.response_compressor(state.stream)

    if compressor && body != "" do
      {Map.put(headers, "content-encoding", compressor.name()),
       compressor.compress(IO.iodata_to_binary(body))}
    else
      {headers, body}
    end
  end

  @doc """
  Replies with an error before the call starts.
  """
  def reply_error(req, http_status, headers, %RPCError{} = error) do
    :cowboy_req.reply(
      http_status,
      Map.put(headers, "content-type", "application/json"),
      Connect.error_body(error),
      req
    )
  end

  @doc """
  Ends the call with the error. A unary call replies with the HTTP status of the error and
  the trailers set so far as headers. A stream ends with an EndStream envelope, in a
  response with status 200 if none has started.
  """
  def send_error(req, %RPCError{} = error, state) do
    if Connect.streaming?(state.stream) do
      envelope = end_stream(error, state)

      case req do
        %{has_sent_resp: _} ->
          :cowboy_req.stream_body(envelope, :fin, req)
          req

        _ ->
          :cowboy_req.reply(200, %{}, envelope, req)
      end
    else
      headers = Map.put(trailer_headers(state), "content-type", "application/json")

      :cowboy_req.reply(
        Connect.status_line(error.status),
        headers,
        Connect.error_body(error),
        req
      )
    end
  end

  defp end_stream(error, state) do
    metadata = state |> Map.get(:resp_trailers, %{}) |> HTTP2.encode_metadata()
    body = IO.iodata_to_binary(Connect.end_stream_body(error, metadata))
    <<@end_stream_flag, byte_size(body)::32, body::binary>>
  end

  # The trailers of a unary response are headers with the prefix `trailer-`.
  defp trailer_headers(state) do
    state
    |> Map.get(:resp_trailers, %{})
    |> HTTP2.encode_metadata()
    |> Map.new(fn {name, value} -> {"trailer-" <> name, value} end)
  end
end
