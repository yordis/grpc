defmodule Conformance.Client.Call do
  @moduledoc """
  Runs one `ClientCompatRequest` against the reference server through the
  library's public client API (`GRPC.Stub` and the generated stubs) and builds
  the `ClientCompatResponse`.

  The pseudocode in the conformance docs ("Testing Clients") drives each stream type.
  """

  alias Connectrpc.Conformance.V1.{
    BidiStreamRequest,
    ClientCompatRequest,
    ClientCompatResponse,
    ClientErrorResult,
    ClientResponseResult,
    ClientStreamRequest,
    ConformancePayload,
    ConformanceService.Stub,
    Error,
    Header,
    IdempotentUnaryRequest,
    ServerStreamRequest,
    UnaryRequest,
    UnimplementedRequest
  }

  alias Conformance.Client.Channels

  @service "connectrpc.conformance.v1.ConformanceService"
  @unknown 2

  # method => {stub function, request module, kind}
  @methods %{
    "Unary" => {:unary, UnaryRequest, :unary},
    "IdempotentUnary" => {:idempotent_unary, IdempotentUnaryRequest, :unary},
    "Unimplemented" => {:unimplemented, UnimplementedRequest, :unary},
    "ServerStream" => {:server_stream, ServerStreamRequest, :server_stream},
    "ClientStream" => {:client_stream, ClientStreamRequest, :client_stream},
    "BidiStream" => {:bidi_stream, BidiStreamRequest, :bidi_stream}
  }

  def run(%ClientCompatRequest{} = req, adapter) do
    result =
      with :ok <- check_service(req),
           {:ok, {fun, req_mod, kind}} <- fetch_method(req),
           {:ok, messages} <- unpack(req, req_mod),
           {:ok, kind} <- check_shape(kind, req, messages) do
        with_channel(req, adapter, fn channel -> invoke(kind, fun, channel, messages, req) end)
      end

    case result do
      {:error, message} when is_binary(message) ->
        %ClientCompatResponse{
          test_name: req.test_name,
          result: {:error, %ClientErrorResult{message: message}}
        }

      %ClientResponseResult{} = response ->
        %ClientCompatResponse{test_name: req.test_name, result: {:response, response}}
    end
  end

  defp check_service(%{service: nil}), do: :ok
  defp check_service(%{service: @service}), do: :ok
  defp check_service(%{service: other}), do: {:error, "unknown service: #{other}"}

  defp fetch_method(%{method: method}) do
    case Map.fetch(@methods, method) do
      {:ok, entry} -> {:ok, entry}
      :error -> {:error, "unknown method: #{inspect(method)}"}
    end
  end

  defp check_shape(kind, %{stream_type: stream_type}, messages) do
    cond do
      kind in [:unary, :server_stream] and length(messages) != 1 ->
        {:error, "#{kind} expects exactly one request message, got #{length(messages)}"}

      kind == :bidi_stream and stream_type == :STREAM_TYPE_FULL_DUPLEX_BIDI_STREAM ->
        {:ok, :full_duplex}

      kind == :bidi_stream ->
        {:ok, :half_duplex}

      true ->
        {:ok, kind}
    end
  end

  defp unpack(%{request_messages: anys}, req_mod) do
    expected = req_mod.full_name()

    Enum.reduce_while(anys, {:ok, []}, fn %Google.Protobuf.Any{type_url: url, value: value},
                                          {:ok, acc} ->
      type = url |> String.split("/") |> List.last()

      if type == expected do
        {:cont, {:ok, acc ++ [req_mod.decode(value)]}}
      else
        {:halt, {:error, "request message type #{type} does not match #{expected}"}}
      end
    end)
  end

  # Connection

  # Cases share channels (see `Conformance.Client.Channels`), except the ones that need a
  # connection of their own, which close it after the call.
  defp with_channel(req, adapter, fun) do
    addr = "#{req.host}:#{req.port}"
    opts = connect_opts(req, adapter)
    shared? = Channels.shared?(req)

    connected =
      if shared?, do: Channels.checkout(addr, opts), else: GRPC.Stub.connect(addr, opts)

    case connected do
      {:ok, channel} ->
        try do
          fun.(channel)
        after
          unless shared?, do: GRPC.Stub.disconnect(channel)
        end

      {:error, error} ->
        {:error, "could not connect: #{inspect(error)}"}
    end
  end

  @doc false
  def connect_opts(req, adapter) do
    [adapter: adapter, codec: codec(req.codec)]
    |> put_protocol(req)
    |> put_compressor(req.compression)
    |> put_cred(req)
  end

  # The gRPC protocol is the default of the library. Connect and gRPC-Web are chosen per
  # channel, together with the HTTP versions the case allows.
  defp put_protocol(opts, %{protocol: :PROTOCOL_CONNECT} = req) do
    opts
    |> Keyword.put(:protocol, :connect)
    |> Keyword.put(:adapter_opts, adapter_opts(req))
  end

  defp put_protocol(opts, %{protocol: :PROTOCOL_GRPC_WEB} = req) do
    opts
    |> Keyword.put(:protocol, :grpc_web)
    |> Keyword.put(:adapter_opts, adapter_opts(req))
  end

  defp put_protocol(opts, _req), do: opts

  # A shared channel carries one HTTP/1.1 call per connection, so it may open as many
  # connections as calls run at once. With fewer, the calls over the limit wait for a
  # connection and fail once the wait is over.
  defp adapter_opts(req) do
    [
      protocols: http_protocols(req.http_version),
      http1_max_connections: Conformance.Client.Main.max_in_flight()
    ]
  end

  defp http_protocols(:HTTP_VERSION_1), do: [:http1]
  defp http_protocols(:HTTP_VERSION_2), do: [:http2]
  defp http_protocols(_), do: [:http1, :http2]

  defp codec(:CODEC_JSON), do: GRPC.Codec.JSON
  defp codec(_), do: GRPC.Codec.Proto

  defp put_compressor(opts, :COMPRESSION_GZIP),
    do: Keyword.put(opts, :compressor, GRPC.Compressor.Gzip)

  defp put_compressor(opts, _), do: opts

  defp put_cred(opts, %{server_tls_cert: <<>>}), do: opts

  defp put_cred(opts, %{server_tls_cert: pem, client_tls_creds: creds}) do
    ssl = Conformance.PinnedCert.ssl_opts(pem) ++ client_creds(creds)
    Keyword.put(opts, :cred, GRPC.Credential.new(ssl: ssl))
  end

  defp client_creds(nil), do: []
  defp client_creds(%{cert: <<>>}), do: []

  defp client_creds(%{cert: cert_pem, key: key_pem}) do
    certs = for {:Certificate, der, :not_encrypted} <- :public_key.pem_decode(cert_pem), do: der
    [{type, der, :not_encrypted} | _] = :public_key.pem_decode(key_pem)
    [cert: hd(certs), key: {type, der}]
  end

  # Call options

  defp call_opts(req) do
    # Without a timeout in the request, send no deadline (the library defaults unary calls to 10s).
    [metadata: metadata(req.request_headers), timeout: req.timeout_ms || :infinity]
    |> put_http_method(req)
    |> put_receive_limit(req)
  end

  # A limit of zero means the request has none.
  defp put_receive_limit(opts, %{message_receive_limit: limit}) when limit > 0,
    do: [{:max_receive_message_length, limit} | opts]

  defp put_receive_limit(opts, _req), do: opts

  defp put_http_method(opts, %{use_get_http_method: true}), do: [{:http_method, :get} | opts]
  defp put_http_method(opts, _req), do: opts

  defp metadata(headers) do
    Enum.reduce(headers, %{}, fn %Header{name: name, value: values}, acc ->
      Map.update(acc, name, Enum.join(values, ","), &(&1 <> "," <> Enum.join(values, ",")))
    end)
  end

  # Unary

  defp invoke(:unary, fun, channel, [message], req) do
    with_cancel_handle(req, fn handle ->
      opts = [return_headers: true] ++ call_opts(req) ++ cancel_opt(handle)

      case apply(Stub, fun, [channel, message, opts]) do
        {:ok, reply, %{headers: headers, trailers: trailers}} ->
          %ClientResponseResult{
            response_headers: headers(headers),
            response_trailers: headers(trailers),
            payloads: [payload(reply)]
          }

        {:error, error} ->
          put_error(%ClientResponseResult{}, error)
      end
    end)
  end

  # Server stream

  defp invoke(:server_stream, fun, channel, [message], req) do
    with_cancel_handle(req, fn handle ->
      opts = [return_headers: true] ++ call_opts(req) ++ cancel_opt(handle)
      cancel = fn -> GRPC.Stub.cancel(handle) end

      case apply(Stub, fun, [channel, message, opts]) do
        {:ok, replies, %{headers: headers}} ->
          consume(replies, new_result(headers), req, 0, cancel)

        {:ok, replies} ->
          consume(replies, new_result(%{}), req, 0, cancel)

        {:error, error} ->
          put_error(%ClientResponseResult{}, error)
      end
    end)
  end

  # Client stream

  defp invoke(:client_stream, fun, channel, messages, req) do
    stream = apply(Stub, fun, [channel, call_opts(req)])

    case send_all(stream, messages, req) do
      {:error, result} ->
        result

      {:ok, stream} ->
        stream = finish_sending(stream, req)

        case GRPC.Stub.recv(stream, [return_headers: true] ++ recv_opts(req)) do
          {:ok, reply, %{headers: headers, trailers: trailers}} ->
            %ClientResponseResult{
              response_headers: headers(headers),
              response_trailers: headers(trailers),
              payloads: [payload(reply)]
            }

          {:error, error} ->
            put_error(%ClientResponseResult{}, error)
        end
    end
  end

  # Half-duplex bidi stream

  defp invoke(:half_duplex, fun, channel, messages, req) do
    stream = apply(Stub, fun, [channel, call_opts(req)])

    case send_all(stream, messages, req) do
      {:error, result} ->
        result

      {:ok, stream} ->
        stream = finish_sending(stream, req)
        receive_stream(stream, req)
    end
  end

  # Full-duplex bidi stream

  defp invoke(:full_duplex, fun, channel, messages, req) do
    stream = apply(Stub, fun, [channel, call_opts(req)])
    total = length(messages)

    step = fn
      {message, index}, {:ok, stream, replies, result} ->
        delay(req)

        case safe_send(stream, message) do
          {:ok, stream} ->
            {replies, result} = take_one(stream, replies, req, result)

            case result.error do
              nil -> {:ok, stream, replies, result}
              _ -> {:halt, %{result | num_unsent_requests: total - index - 1}}
            end

          {:error, error} ->
            {:halt, %{put_error(result, error) | num_unsent_requests: total - index}}
        end
    end

    initial = {:ok, stream, nil, new_result(%{})}

    loop =
      messages
      |> Enum.with_index()
      |> Enum.reduce_while(initial, fn item, acc ->
        case step.(item, acc) do
          {:halt, result} -> {:halt, {:done, result}}
          next -> {:cont, next}
        end
      end)

    case loop do
      {:done, result} ->
        result

      {:ok, stream, replies, result} ->
        stream = finish_sending(stream, req)
        drain_replies(stream, replies, result, req)
    end
  end

  # Sending

  defp send_all(stream, messages, req) do
    total = length(messages)

    messages
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, stream}, fn {message, index}, {:ok, stream} ->
      delay(req)

      case safe_send(stream, message) do
        {:ok, stream} ->
          {:cont, {:ok, stream}}

        {:error, error} ->
          result = %{
            put_error(%ClientResponseResult{}, error)
            | num_unsent_requests: total - index
          }

          {:halt, {:error, result}}
      end
    end)
  end

  defp safe_send(stream, message) do
    case GRPC.Stub.send_request(stream, message) do
      %GRPC.Client.Stream{} = stream -> {:ok, stream}
      {:error, error} -> {:error, error}
      other -> {:error, "unexpected send result: #{inspect(other)}"}
    end
  rescue
    error -> {:error, error}
  end

  defp finish_sending(stream, req) do
    stream =
      case req.cancel do
        %{cancel_timing: {:before_close_send, _}} -> GRPC.Stub.cancel(stream)
        _ -> stream
      end

    stream = GRPC.Stub.end_stream(stream)

    case req.cancel do
      %{cancel_timing: {:after_close_send_ms, ms}} ->
        Process.sleep(ms)
        GRPC.Stub.cancel(stream)

      _ ->
        stream
    end
  end

  defp delay(%{request_delay_ms: 0}), do: :ok
  defp delay(%{request_delay_ms: ms}), do: Process.sleep(ms)

  # Receiving

  defp receive_stream(stream, req) do
    case GRPC.Stub.recv(stream, [return_headers: true] ++ recv_opts(req)) do
      {:ok, replies, %{headers: headers}} ->
        consume(replies, new_result(headers), req, 0, fn -> GRPC.Stub.cancel(stream) end)

      {:ok, replies} ->
        consume(replies, new_result(%{}), req, 0, fn -> GRPC.Stub.cancel(stream) end)

      {:error, error} ->
        put_error(%ClientResponseResult{}, error)
    end
  end

  defp recv_opts(%{timeout_ms: nil}), do: []
  defp recv_opts(%{timeout_ms: ms}), do: [timeout: ms]

  defp new_result(headers), do: %ClientResponseResult{response_headers: headers(headers)}

  # Consumes a reply enumerable to the end. After N responses, when the request says so,
  # it cancels the call and goes on reading: the end is whatever the library returns.
  defp consume(replies, result, req, seen, cancel) do
    after_n = after_num_responses(req)

    outcome =
      Enum.reduce_while(replies, {result, seen}, fn item, {result, seen} ->
        case item do
          {:ok, reply} ->
            result = %{result | payloads: result.payloads ++ [payload(reply)]}
            seen = seen + 1
            if after_n == seen, do: cancel.()
            {:cont, {result, seen}}

          {:trailers, trailers} ->
            {:cont, {%{result | response_trailers: headers(trailers)}, seen}}

          {:error, error} ->
            {:halt, {put_error(result, error), seen}}
        end
      end)

    elem(outcome, 0)
  end

  # Full duplex: one reply after each send. Replies are an Enumerable read in steps
  # (see GRPC.Stub.recv/2), so the first call obtains it and later calls reuse it.
  defp take_one(stream, nil, req, result) do
    case GRPC.Stub.recv(stream, [return_headers: true] ++ recv_opts(req)) do
      {:ok, replies, %{headers: headers}} ->
        take_one(stream, replies, req, %{result | response_headers: headers(headers)})

      {:ok, replies} ->
        take_one(stream, replies, req, result)

      {:error, error} ->
        {nil, put_error(result, error)}
    end
  end

  defp take_one(stream, replies, req, result) do
    {replies, apply_items(stream, Enum.take(replies, 1), result, req)}
  end

  defp drain_replies(stream, nil, result, req) do
    case take_one(stream, nil, req, result) do
      {nil, result} -> result
      {replies, result} -> drain_replies(stream, replies, result, req)
    end
  end

  defp drain_replies(stream, replies, result, req) do
    consume_rest(stream, replies, result, req)
  end

  defp consume_rest(stream, replies, result, req) do
    seen = length(result.payloads)

    case result.error do
      nil -> consume(replies, result, req, seen, fn -> GRPC.Stub.cancel(stream) end)
      _ -> result
    end
  end

  defp apply_items(stream, items, result, req) do
    after_n = after_num_responses(req)

    Enum.reduce(items, result, fn
      {:ok, reply}, result ->
        result = %{result | payloads: result.payloads ++ [payload(reply)]}
        if after_n == length(result.payloads), do: GRPC.Stub.cancel(stream)
        result

      {:trailers, trailers}, result ->
        %{result | response_trailers: headers(trailers)}

      {:error, error}, result ->
        put_error(result, error)
    end)
  end

  defp after_num_responses(%{cancel: %{cancel_timing: {:after_num_responses, n}}}), do: n
  defp after_num_responses(_req), do: nil

  # A unary or server-streaming call is cancelled through a handle: after the time the
  # request names, or after N responses (see `consume/5`).
  defp with_cancel_handle(%{cancel: nil}, fun), do: fun.(nil)

  defp with_cancel_handle(%{cancel: %{cancel_timing: timing}}, fun) do
    handle = GRPC.Stub.new_cancel_handle()

    timer =
      case timing do
        {:after_close_send_ms, ms} ->
          spawn(fn ->
            Process.sleep(ms)
            GRPC.Stub.cancel(handle)
          end)

        _ ->
          nil
      end

    try do
      fun.(handle)
    after
      if timer, do: Process.exit(timer, :kill)
    end
  end

  defp cancel_opt(nil), do: []
  defp cancel_opt(handle), do: [cancel: handle]

  # Conversions

  defp payload(%{payload: %ConformancePayload{} = payload}), do: payload
  defp payload(_), do: %ConformancePayload{}

  defp headers(nil), do: []

  defp headers(map) when is_map(map) do
    map
    |> Enum.reject(fn {name, _} -> String.starts_with?(to_string(name), ":") end)
    |> Enum.sort()
    |> Enum.map(fn {name, value} -> %Header{name: to_string(name), value: [to_string(value)]} end)
  end

  # An error carries the response headers and trailers the server sent with it.
  defp put_error(result, error) do
    result = %{result | error: to_error(error)}

    case error do
      %GRPC.RPCError{headers: headers, trailers: trailers} ->
        %{
          result
          | response_headers:
              if(result.response_headers == [],
                do: headers(headers),
                else: result.response_headers
              ),
            response_trailers: headers(trailers)
        }

      _ ->
        result
    end
  end

  defp to_error(%GRPC.RPCError{status: status, message: message, details: details}) do
    %Error{code: status, message: message, details: any_details(details)}
  end

  defp to_error(%{__exception__: true} = error),
    do: %Error{code: @unknown, message: Exception.message(error)}

  defp to_error(other), do: %Error{code: @unknown, message: inspect(other)}

  defp any_details(details) when is_list(details),
    do: Enum.filter(details, &match?(%Google.Protobuf.Any{}, &1))

  defp any_details(_), do: []
end
