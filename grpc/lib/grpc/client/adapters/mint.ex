if Code.ensure_loaded?(Mint.HTTP) do
  defmodule GRPC.Client.Adapters.Mint do
    @moduledoc """
    A client adapter using Mint.

    This adapter requires a compatible version of `:mint` to use. Add `:mint` to
    your project's dependencies, then recompile `:grpc`:

    ```shell
    mix deps.clean grpc
    mix deps.compile grpc
    ```

    ## Server GOAWAY

    When the server sends GOAWAY with `NO_ERROR`, for example after `:max_connection_age`,
    the calls that are open finish on the old connection.

    With the connection pool (`config :grpc, pool_enabled: true`), the pool sends new calls
    to a new connection. It removes the old connection when its last call ends.

    Without the pool, a call that starts during the drain fails with `UNAVAILABLE`. The
    client connects again when the drain ends. Gun does not have this limit.

    A call that the pool gave to the old connection just before the GOAWAY fails with
    `UNAVAILABLE` too. The server did not process it, so a retry is safe.

    Mint takes no request body on a connection after GOAWAY, not even the end of the
    stream. A client-streaming or bidirectional call can be open at GOAWAY without an
    ended request stream. It cannot send more messages or end the stream. The adapter
    drops the stream and the call fails with `UNAVAILABLE`. Mint 1.9 sends no RST_STREAM
    after GOAWAY, so the server sees the stream end when the connection closes.

    A send that times out on a busy connection process exits to the caller. The
    response stays open.
    """

    alias GRPC.Channel
    alias GRPC.Client.Connect
    alias GRPC.Client.HTTPVersions
    alias GRPC.Client.Adapters.Mint.ConnectionProcess
    alias GRPC.Client.Adapters.Mint.StreamResponseProcess
    alias GRPC.Credential

    @behaviour GRPC.Client.Adapter

    @default_client_settings [
      initial_window_size: 8_000_000,
      max_frame_size: 8_000_000
    ]
    @default_transport_opts [timeout: 20_000, nodelay: true]
    @cleanup_timeout 1_000
    @unavailable GRPC.Status.unavailable()

    @doc """
    Connects using Mint based on the provided configs. Options
      * `:transport_opts`: Defaults to `[timeout: 20_000, nodelay: true]`. `timeout` bounds the whole connect, including
        the wait for the server's first SETTINGS frame, but not streams.
        `nodelay: true` sets `TCP_NODELAY`, so small writes go out at once instead of waiting on Nagle's algorithm and
        delayed ACKs, which adds tens of milliseconds to sequential calls. Pass `nodelay: false` to turn it off. The other
        options may vary based on the transport used for this connection (tcp or ssl). Check [Mint.HTTP.connect/4](https://hexdocs.pm/mint/Mint.HTTP.html#connect/4)
      * `:client_settings`: Defaults to `[initial_window_size: 8_000_000, max_frame_size: 8_000_000]`, a larger default
        window size ensures that the number of packages exchanges is smaller, thus speeding up the requests by reducing the
        amount of networks round trip, with the cost of having larger packages reaching the server per connection.
        Check [Mint.HTTP2.setting() type](https://hexdocs.pm/mint/Mint.HTTP2.html#t:setting/0) for additional configs.
      * `:retry`: Number of reconnection attempts when the connection drops, or `:infinity`
        to keep reconnecting for as long as the process lives. Defaults to `0` (no retries).
        Uses exponential backoff with jitter between attempts.
      * `:keepalive`: Interval in milliseconds between HTTP/2 PING frames sent to the server.
        Defaults to `nil` (no pings).
      * `:keepalive_tolerance`: Number of unacknowledged pings after which the connection is closed,
        triggering `:retry` if configured. Defaults to `nil` (never close). Has no effect without `:keepalive`.
      * `:http1_max_connections`: the most connections the channel opens over HTTP/1.1, default `8`.
        HTTP/1.1 carries one call at a time on a connection, so a call that finds the channel's
        connection busy opens another one for itself, up to this limit. Calls over it wait for a
        connection to free, for at most 5 seconds or until their own deadline or cancel, and fail with
        `UNAVAILABLE` (or `DEADLINE_EXCEEDED`, `CANCELLED`). A positive integer, where `1` makes the calls take the one connection in turn. HTTP/2 ignores it.
      * `:protocols`: for `protocol: :connect` and `protocol: :grpc_web`, a non-empty list of the HTTP
        versions to allow, from `:http1` and `:http2`. With `https://` the version is negotiated with
        ALPN, and the default allows both. With `http://` there is no negotiation: the adapter speaks
        HTTP/2 with prior knowledge unless the list is `[:http1]`. `protocol: :grpc` runs on HTTP/2 only
        and takes no `:protocols` other than `[:http2]`. A value that is not valid raises `ArgumentError`
        from `GRPC.Stub.connect/2`.
    """
    @impl true
    def connect(%Channel{} = channel, opts \\ []) do
      {retry, opts} = Keyword.pop(opts, :retry, 0)

      with :ok <- validate_retry(retry),
           {:ok, pid} <- start_connection_process(channel, opts, retry) do
        {:ok, %{channel | adapter_payload: %{conn_pid: pid}}}
      end
    catch
      :exit, reason -> {:error, reason}
    end

    # Every key `connect/2` and the connection pool read from the adapter options.
    # `:logical_connection_ref` and `:notify_drain` are added by the pool, not by the caller.
    @valid_opts [
      :retry,
      :transport_opts,
      :client_settings,
      :protocols,
      :keepalive,
      :keepalive_tolerance,
      :http1_max_connections,
      :config_options,
      :logical_connection_ref,
      :notify_drain
    ]

    @impl true
    def supported_protocols, do: [:grpc, :connect, :grpc_web]

    @impl true
    def validate_opts(opts) do
      with :ok <- validate_known_opts(opts),
           :ok <- validate_retry(opts[:retry]),
           do: GRPC.Client.HTTP1Lanes.validate(opts)
    end

    @impl true
    def validate_opts(opts, protocol) do
      with :ok <- validate_opts(opts), do: HTTPVersions.validate(protocol, opts)
    end

    @impl true
    def disconnect(%{adapter_payload: %{conn_pid: pid}} = channel)
        when is_pid(pid) do
      :ok = ConnectionProcess.disconnect(pid)
      {:ok, %{channel | adapter_payload: %{conn_pid: nil}}}
    end

    def disconnect(%{adapter_payload: %{conn_pid: nil}} = channel) do
      {:ok, channel}
    end

    @impl true
    def send_request(%{channel: %{adapter_payload: %{conn_pid: nil}}}, _message, _opts),
      do: raise(ArgumentError, "Can't perform a request without a connection process")

    def send_request(%{channel: %{protocol: :connect}} = stream, message, opts) do
      if opts[:http_method] == :get and Connect.kind(stream) == :unary do
        do_request(%{stream | path: Connect.get_path(stream, message, opts)}, opts, nil, "GET")
      else
        do_request(stream, opts, connect_body(stream, message, opts))
      end
    end

    def send_request(stream, message, opts) do
      {:ok, data, _} = GRPC.Message.to_data(message, opts)
      do_request(stream, opts, data)
    end

    # A unary call sends its message as the body. The other kinds send an envelope.
    defp connect_body(stream, message, opts) do
      case Connect.kind(stream) do
        :unary ->
          Connect.unary_body(message, opts[:compressor])

        :stream ->
          {:ok, data, _} = GRPC.Message.to_data(message, opts)
          data
      end
    end

    @impl true
    def receive_data(stream, opts) do
      if success_response?(stream) do
        do_receive_data(stream, stream.grpc_type, opts)
      else
        handle_errors_receive_data(stream, opts)
      end
    end

    @impl true
    def send_headers(%{channel: %{adapter_payload: %{conn_pid: nil}}}, _opts),
      do: raise("Can't start a client stream without a connection process")

    def send_headers(stream, opts) do
      do_request(stream, opts, :stream)
    end

    @impl true
    def send_data(
          %{
            payload: %{response: {:ok, %{request_ref: request_ref}}}
          } = stream,
          message,
          opts
        ) do
      pid = conn_pid(stream)
      {:ok, data, _} = GRPC.Message.to_data(message, opts)
      :ok = stream_body(stream, pid, request_ref, data)
      if opts[:send_end_stream], do: stream_body(stream, pid, request_ref, :eof)
      stream
    end

    @impl true
    def end_stream(%{payload: %{response: {:ok, %{request_ref: request_ref}}}} = stream) do
      pid = conn_pid(stream)
      stream_body(stream, pid, request_ref, :eof)
      stream
    end

    @impl true
    # A call that failed before it was sent has nothing to cancel.
    def cancel(%{payload: %{response: {:error, _error}}}), do: :ok

    def cancel(stream) do
      %{payload: %{response: {:ok, %{request_ref: request_ref}}}} = stream

      ConnectionProcess.cancel(conn_pid(stream), request_ref)
    end

    # A call that found an HTTP/1.1 connection busy runs on a connection of its own.
    defp conn_pid(%{payload: %{response: {:ok, %{conn_pid: pid}}}}), do: pid
    defp conn_pid(%{channel: %{adapter_payload: %{conn_pid: pid}}}), do: pid

    # After GOAWAY the connection process fails the call with UNAVAILABLE and gives the
    # error to the response process, so `receive_data/2` returns it. Do not crash here.
    defp stream_body(stream, pid, request_ref, body) do
      case ConnectionProcess.stream_request_body(pid, request_ref, body) do
        {:error, %GRPC.RPCError{status: @unavailable}} -> :ok
        result -> result
      end
    catch
      # The connection process is gone, or died during the call (`:noproc`, `:normal`,
      # `:killed`, `:shutdown` or a crash). Nothing may have told the response process,
      # so end it here. Else `receive_data/2` waits forever.
      # A `:timeout` means the process is alive but busy. The exit goes to the caller as
      # before, and the response stays open, because the request may still go through.
      :exit, {reason, {GenServer, :call, _args}} when reason != :timeout ->
        fail_response(stream)
    end

    # The response process ignores this error if the response has ended.
    defp fail_response(%{payload: %{stream_response_pid: pid}}) do
      error = GRPC.RPCError.exception(@unavailable, "the connection is closed")
      StreamResponseProcess.consume(pid, :error, error)
      StreamResponseProcess.done(pid)
      :ok
    end

    defp validate_known_opts(opts) do
      case for({key, _value} <- opts, key not in @valid_opts, do: key) do
        [] -> :ok
        unknown -> {:error, unknown_opts_message(unknown)}
      end
    end

    defp unknown_opts_message(unknown) do
      message =
        "unknown option(s) for the Mint adapter: #{inspect(unknown)}. " <>
          "Valid options are: #{inspect(@valid_opts -- [:logical_connection_ref, :notify_drain])}."

      if :custom_opts in unknown do
        message <>
          " TLS certificates and keys go in the :cred option of GRPC.Stub.connect/2, " <>
          "as GRPC.Credential.new(ssl: [...])."
      else
        message
      end
    end

    defp validate_retry(nil), do: :ok
    defp validate_retry(:infinity), do: :ok
    defp validate_retry(retry) when is_integer(retry) and retry >= 0, do: :ok

    defp validate_retry(retry),
      do: {:error, ":retry must be a non-negative integer or :infinity, got: #{inspect(retry)}"}

    defp connect_opts(%Channel{scheme: "https"} = channel, opts) do
      %Credential{ssl: ssl} = Map.get(channel, :cred) || %Credential{}

      transport_opts =
        opts
        |> Keyword.get(:transport_opts, [])
        |> Keyword.merge(ssl)

      client_settings = Keyword.get(opts, :client_settings, @default_client_settings)

      [
        transport_opts: Keyword.merge(@default_transport_opts, transport_opts),
        client_settings: client_settings
      ]
    end

    defp connect_opts(_channel, opts) do
      transport_opts = Keyword.get(opts, :transport_opts, [])
      client_settings = Keyword.get(opts, :client_settings, @default_client_settings)

      [
        transport_opts: Keyword.merge(@default_transport_opts, transport_opts),
        client_settings: client_settings
      ]
    end

    # See `GRPC.Client.HTTPVersions` for how the version is picked.
    defp put_protocols(opts, %Channel{protocol: protocol} = channel, protocols) do
      transport = if mint_scheme(channel) == :https, do: :tls, else: :tcp
      Keyword.put(opts, :protocols, HTTPVersions.select(protocol, protocols, transport))
    end

    defp mint_scheme(%Channel{scheme: "https"} = _channel), do: :https
    defp mint_scheme(_channel), do: :http

    defp start_connection_process(%{host: host, port: port} = channel, opts, retry) do
      {config_opts, opts} = Keyword.pop(opts, :config_options, [])
      # Pooled connections open with `ref: nil`, so the pool passes the logical ref separately
      {logical_ref, opts} = Keyword.pop(opts, :logical_connection_ref, channel.ref)
      {keepalive_opts, opts} = Keyword.split(opts, [:keepalive, :keepalive_tolerance])
      {notify_drain, opts} = Keyword.pop(opts, :notify_drain, false)
      module_opts = Application.get_env(:grpc, __MODULE__, config_opts)

      transport_metadata = %{
        logical_connection_ref: logical_ref,
        target: {host, port},
        adapter: __MODULE__
      }

      {protocols, opts} = Keyword.pop(opts, :protocols)
      {max_http1, opts} = Keyword.pop(opts, :http1_max_connections)

      opts =
        channel
        |> connect_opts(opts)
        |> then(&if max_http1, do: Keyword.put(&1, :http1_max_connections, max_http1), else: &1)
        |> Keyword.merge(module_opts)
        |> put_protocols(channel, protocols)
        |> Keyword.put(:retry, retry)
        |> Keyword.put(:notify_drain, notify_drain)
        |> Keyword.put(:grpc_transport_metadata, transport_metadata)
        |> Keyword.merge(keepalive_opts)

      # A dns:// target resolves to an address (the host we dial) while the
      # hostname it resolved from must still reach TLS for SNI and certificate
      # verification.
      opts =
        if channel.hostname, do: Keyword.put(opts, :hostname, channel.hostname), else: opts

      Process.flag(:trap_exit, true)

      channel
      |> mint_scheme()
      |> ConnectionProcess.start_link(host, port, opts)
    end

    defp do_receive_data(
           %{payload: %{stream_response_pid: pid}} = grpc_stream,
           request_type,
           opts
         )
         when request_type in [:bidirectional_stream, :server_stream] do
      produce_trailers? = opts[:return_headers] == true

      stream =
        pid
        |> StreamResponseProcess.build_stream(produce_trailers?, call_timeout(grpc_stream))
        |> Stream.map(&deadline_error(&1, grpc_stream, pid))

      headers_or_error = Enum.at(stream, 0)
      # if this check fails then an error tuple will be returned
      with {:headers, headers} <- headers_or_error do
        stream = reset_on_halt(stream, grpc_stream, pid, request_type)

        if opts[:return_headers] do
          {:ok, stream, %{headers: headers}}
        else
          {:ok, stream}
        end
      end
    end

    defp do_receive_data(
           %{payload: %{stream_response_pid: pid}} = stream,
           request_type,
           opts
         )
         when request_type in [:client_stream, :unary] do
      responses =
        pid
        |> StreamResponseProcess.build_stream(true, recv_timeout(stream, request_type, opts))
        |> Enum.to_list()

      case check_for_error(responses) do
        :ok ->
          case Keyword.get_values(responses, :ok) do
            [data] ->
              if opts[:return_headers] do
                {:ok, data, get_headers_and_trailers(responses)}
              else
                {:ok, data}
              end

            [] ->
              GRPC.Client.Telemetry.mark_rpc_failure(:remote, nil)

              {:error,
               GRPC.RPCError.exception(GRPC.Status.unimplemented(), "Missing response message.")}

            _several ->
              GRPC.Client.Telemetry.mark_rpc_failure(:remote, nil)

              {:error,
               GRPC.RPCError.exception(
                 GRPC.Status.unimplemented(),
                 "Received more than one message for a call that returns one."
               )}
          end

        {:error, :deadline_exceeded} ->
          give_up_on_request(stream, pid)
          GRPC.Client.Telemetry.mark_rpc_failure(:after_dispatch, :deadline)

          {:error, GRPC.RPCError.exception(GRPC.Status.deadline_exceeded(), "deadline exceeded")}

        {:error, %GRPC.RPCError{message: "the connection is closed"} = error} ->
          GRPC.Client.Telemetry.mark_rpc_failure(:after_dispatch, :connection_unavailable)
          {:error, error}

        {:error, %GRPC.RPCError{} = error} ->
          GRPC.Client.Telemetry.mark_rpc_failure(:remote, nil)
          {:error, error}

        {:error, %Mint.HTTPError{reason: {:server_closed_request, :cancel}} = error} ->
          if reset_at_deadline?(stream) do
            give_up_on_request(stream, pid)
            GRPC.Client.Telemetry.mark_rpc_failure(:after_dispatch, :deadline)

            {:error,
             GRPC.RPCError.exception(GRPC.Status.deadline_exceeded(), "deadline exceeded")}
          else
            mark_transport_failure(error)
            {:error, rpc_error({:error, error})}
          end

        {:error, error} ->
          mark_transport_failure(error)
          {:error, rpc_error({:error, error})}
      end
    end

    defp reset_at_deadline?(%{payload: %{deadline: deadline}}),
      do: GRPC.Client.ResetCode.at_deadline?(deadline)

    defp reset_at_deadline?(_stream), do: false

    # Only unary receives are bounded. Server and bidirectional streams are
    # consumed lazily by the caller, where a gap between messages is expected
    # rather than a failure, and a client stream awaits its response through a
    # separate `GRPC.Stub.recv/2` call, which `GRPC.Stub` documents as unbounded
    # even though it fills in the same 10s default.
    defp recv_timeout(_stream, :unary, opts) do
      # An explicit `:deadline` wins: `GRPC.Stub` always fills in a `:timeout`,
      # so a deadline could never take effect otherwise. Both arrive here as a
      # float number of milliseconds, already negative for a deadline in the
      # past, while a receive timeout has to be a non-negative integer.
      case opts[:deadline] || opts[:timeout] do
        nil -> :infinity
        :infinity -> :infinity
        milliseconds when is_number(milliseconds) -> max(0, round(milliseconds))
      end
    end

    defp recv_timeout(stream, :client_stream, _opts), do: call_timeout(stream)

    # The caller stopped waiting on a request that is still open. Reset it so the
    # server stops working on it, and stop the process that buffers the response:
    # it is linked to the caller rather than to the connection, so nothing else
    # shuts it down — least of all when the connection process is the very thing
    # that went away.
    defp give_up_on_request(stream, stream_response_pid) do
      %{payload: %{response: {:ok, %{request_ref: request_ref}}}} = stream
      conn_pid = conn_pid(stream)

      quietly(fn -> ConnectionProcess.cancel(conn_pid, request_ref, @cleanup_timeout) end)
      quietly(fn -> GenServer.stop(stream_response_pid, :normal, @cleanup_timeout) end)
    end

    # Cleanup runs after the deadline already elapsed, against processes that may
    # be gone or wedged — which is what the deadline exists for. Failing to tidy
    # up must neither replace the error the caller is about to get nor keep it
    # waiting much longer.
    defp quietly(cleanup) do
      cleanup.()
    catch
      :exit, _reason -> :ok
    end

    def handle_errors_receive_data(
          %GRPC.Client.Stream{payload: %{response: response, stream_response_pid: pid}},
          _opts
        ) do
      quietly(fn -> GenServer.stop(pid, :normal, @cleanup_timeout) end)

      {:error, rpc_error(response)}
    end

    # A connection that has dropped, or was never there, is a transient condition
    # that should map to the gRPC UNAVAILABLE error status.
    # The call's timeout bounds a streaming call as a whole, as it does with Gun.
    defp deadline_error({:error, :deadline_exceeded}, stream, pid) do
      give_up_on_request(stream, pid)
      GRPC.Client.Telemetry.mark_rpc_failure(:after_dispatch, :deadline)
      {:error, GRPC.RPCError.exception(GRPC.Status.deadline_exceeded(), "deadline exceeded")}
    end

    # A reset or a closed connection reaches the stream as the Mint error, which
    # must not leak out of the client.
    defp deadline_error(
           {:error, %Mint.HTTPError{reason: {:server_closed_request, :cancel}} = error},
           stream,
           pid
         ) do
      if reset_at_deadline?(stream) do
        deadline_error({:error, :deadline_exceeded}, stream, pid)
      else
        {:error, rpc_error({:error, error})}
      end
    end

    defp deadline_error({:error, %mod{} = error}, _stream, _pid)
         when mod in [Mint.HTTPError, Mint.TransportError] do
      {:error, rpc_error({:error, error})}
    end

    defp deadline_error(response, _stream, _pid), do: response

    # A caller that stops reading a server stream before its end, as `Enum.take/2` does, has no
    # use for the rest of it. Reset the request, and stop the process that buffers the reply.
    # A bidirectional stream is read in parts, so there it stays open until the caller ends.
    defp reset_on_halt(stream, grpc_stream, pid, :server_stream) do
      Stream.transform(
        stream,
        fn -> :ok end,
        fn item, acc -> {[item], acc} end,
        fn acc -> {[], acc} end,
        fn _acc -> if Process.alive?(pid), do: give_up_on_request(grpc_stream, pid) end
      )
    end

    defp reset_on_halt(stream, _grpc_stream, _pid, _request_type), do: stream

    defp call_timeout(%{payload: %{deadline: deadline}}) when is_integer(deadline),
      do: {:deadline, deadline}

    defp call_timeout(_stream), do: :infinity

    defp rpc_error({:error, %GRPC.RPCError{} = error}), do: error

    defp rpc_error({:error, %Mint.TransportError{} = error}) do
      unavailable(error)
    end

    defp rpc_error({:error, %Mint.HTTPError{reason: :closed} = error}) do
      unavailable(error)
    end

    defp rpc_error({:error, %Mint.HTTPError{reason: :closed_for_writing} = error}) do
      unavailable(error)
    end

    defp rpc_error({:error, %Mint.HTTPError{reason: :unprocessed} = error}) do
      unavailable(error)
    end

    defp rpc_error({:error, %Mint.HTTPError{reason: {:server_closed_connection, _, _}} = error}) do
      unavailable(error)
    end

    defp rpc_error({:error, %Mint.HTTPError{reason: {:server_closed_request, code}}}) do
      GRPC.Client.ResetCode.error(code)
    end

    defp rpc_error({:error, :closed}) do
      GRPC.RPCError.exception(GRPC.Status.unavailable(), "the connection is closed")
    end

    defp rpc_error(response) do
      GRPC.RPCError.exception(
        GRPC.Status.unknown(),
        "error occurred while receiving data: #{inspect(response)}"
      )
    end

    defp unavailable(error) do
      GRPC.RPCError.exception(GRPC.Status.unavailable(), Exception.message(error))
    end

    defp success_response?(%GRPC.Client.Stream{
           payload: %{response: {:ok, _resp}}
         }),
         do: true

    defp success_response?(_stream), do: false

    defp do_request(
           %{channel: %{adapter_payload: %{conn_pid: pid}}, path: path} = stream,
           opts,
           body,
           method \\ "POST"
         ) do
      headers = request_headers(stream, opts, method)

      {:ok, stream_response_pid} =
        StreamResponseProcess.start_link(stream, return_headers_for_request?(stream, opts))

      response =
        try do
          ConnectionProcess.request(pid, method, path, headers, body,
            stream_response_pid: stream_response_pid,
            protocol: stream.channel.protocol,
            deadline: request_deadline(opts[:deadline] || opts[:timeout]),
            cancel: opts[:cancel]
          )
        catch
          :exit, reason ->
            quietly(fn -> GenServer.stop(stream_response_pid, :normal, @cleanup_timeout) end)
            :erlang.raise(:exit, reason, __STACKTRACE__)
        end

      stream
      |> GRPC.Client.Stream.put_payload(:response, response)
      |> GRPC.Client.Stream.put_payload(:stream_response_pid, stream_response_pid)
      |> GRPC.Client.Stream.put_payload(:deadline, request_deadline(opts[:timeout]))
    end

    defp request_headers(%{channel: %{protocol: :connect}} = stream, opts, method),
      do: Connect.request_headers(stream, opts, method)

    defp request_headers(%{channel: %{protocol: :grpc_web}} = stream, opts, _method),
      do: GRPC.Client.GrpcWeb.request_headers(stream, opts)

    defp request_headers(stream, opts, _method),
      do: GRPC.Transport.HTTP2.client_headers_without_reserved(stream, opts)

    defp request_deadline(timeout) when is_integer(timeout),
      do: System.monotonic_time(:millisecond) + max(timeout, 0)

    defp request_deadline(milliseconds) when is_number(milliseconds),
      do: System.monotonic_time(:millisecond) + max(0, round(milliseconds))

    defp request_deadline(_timeout), do: nil

    defp get_headers_and_trailers(responses) do
      %{headers: Keyword.get(responses, :headers), trailers: Keyword.get(responses, :trailers)}
    end

    def check_for_error(responses) do
      error = Keyword.get(responses, :error)

      if error, do: {:error, error}, else: :ok
    end

    # A client stream's request is opened before `recv/2` says whether the caller wants
    # the headers, so it keeps them, as the streaming calls do.
    defp return_headers_for_request?(%GRPC.Client.Stream{grpc_type: type}, _opts)
         when type in [:bidirectional_stream, :server_stream, :client_stream] do
      true
    end

    defp return_headers_for_request?(_stream, opts) do
      # Explicitly check for true to ensure the boolean type here
      opts[:return_headers] == true
    end

    defp mark_transport_failure(%Mint.TransportError{}) do
      GRPC.Client.Telemetry.mark_rpc_failure(:after_dispatch, :connection_unavailable)
    end

    defp mark_transport_failure(%Mint.HTTPError{reason: {:server_closed_request, _code}}) do
      GRPC.Client.Telemetry.mark_rpc_failure(:after_dispatch, :stream_error)
    end

    defp mark_transport_failure(%Mint.HTTPError{reason: reason})
         when reason in [:closed, :closed_for_writing, :unprocessed] do
      GRPC.Client.Telemetry.mark_rpc_failure(:after_dispatch, :connection_unavailable)
    end

    defp mark_transport_failure(%Mint.HTTPError{reason: {:server_closed_connection, _, _}}) do
      GRPC.Client.Telemetry.mark_rpc_failure(:after_dispatch, :connection_unavailable)
    end

    defp mark_transport_failure(_error), do: :ok
  end
end
