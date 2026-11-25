if Code.ensure_loaded?(:gun) do
  defmodule GRPC.Client.Adapters.Gun do
    @moduledoc """
    A client adapter using Gun.

    `conn_pid` stores the adapter-managed connection process pid and per-request
    `stream_ref` values are stored in `GRPC.Client.Stream`.

    This adapter requires a compatible version of `:gun` to use. Add `:gun` to
    your project's dependencies, then recompile `:grpc`:

    ```shell
    mix deps.clean grpc
    mix deps.compile grpc
    ```

    ## Options

    Options in `:adapter_opts` that this adapter reads itself, besides the ones Gun takes:

      * `:protocols` - for `protocol: :connect` and `protocol: :grpc_web`, a non-empty list of
        the HTTP versions to allow, from `:http1` and `:http2` (not Gun's own names). With
        `https://` the version is negotiated with ALPN, and the default allows both. With
        `http://` there is no negotiation: the adapter speaks HTTP/2 with prior knowledge
        unless the list is `[:http1]`. `protocol: :grpc` runs on HTTP/2 only and takes no
        `:protocols` other than `[:http2]`. The Mint adapter reads the same option the
        same way.

      * `:response_window` - bytes of a response the adapter reads ahead of the
        caller, per stream (default: `1_048_576`). The least value is `16_384`, one
        HTTP/2 frame. Gun counts the window in DATA frames, `ceil(window / 16_384)`
        of them. Gun stops sending the stream's window updates once that many
        frames are unread, and the adapter reopens the window as the caller takes
        messages, so a slow consumer slows the server instead of filling memory.
        `:infinity` turns the limit off.

    The window limits bytes more than entries. After the frame count is used up,
    the peer can still fill what is left of the HTTP/2 stream window. Gun's
    stream window is set to `:response_window` unless `:http2_opts` gives
    `:initial_stream_window_size`, and cowlib adds 65,535 bytes each time Gun
    reopens it (`cow_http2_machine:ensure_window/3`, option
    `stream_window_margin_size`). The queue therefore holds at most
    `ceil(window / 16_384)` frames of 16 KiB, plus `window + 65_535` bytes.
    Each queued entry is one DATA frame. A server that sends one small message
    per frame fills those bytes with many small entries, for example about 16,000
    entries of 8 bytes for a 64 KiB window. A larger `max_frame_size_received` in
    `:http2_opts` raises the byte limit in the same way.

    A message larger than the window still arrives in full, because each read of
    a frame reopens the window. A stream window under one frame would stall
    cowlib senders, which hold data back when the stream window is under 16,384
    bytes and the data does not fit. A WINDOW_UPDATE would restart such a
    stream. Gun sends none before it receives data. A held-back stream sends
    none. The adapter therefore also rejects
    `http2_opts: %{initial_stream_window_size: n}` when `n` is not an integer,
    or is under `16_384`. The option is the stream window that Gun announces, so
    the check does not depend on `:response_window`.

    `initial_connection_window_size` has no such floor. A cowlib sender holds
    data back only when the stream window is under 16,384 bytes. The adapter
    rejects a value that is not an integer, or is under `65_535`, for another
    reason: cowlib subtracts 65,535 in `cow_http2_machine:common_preface/1`, and
    `update_window/2` raises `FunctionClauseError`, so the connection does not
    open.
    """

    @behaviour GRPC.Client.Adapter

    alias GRPC.Client.Adapter
    alias GRPC.Client.Connect
    alias GRPC.Client.Adapters.Gun.ConnectionProcess

    @default_tcp_opts [nodelay: true]
    @max_retries 100
    # Default of `:response_window`, in bytes.
    @default_response_window 1_048_576
    @deadline_tolerance 1
    # One frame. A smaller window stalls a cowlib peer, which holds data back
    # while the stream window is under 16,384 bytes and the data does not fit.
    @min_response_window 16_384
    # The HTTP/2 default connection window. cowlib crashes below it.
    @min_connection_window 65_535

    @impl true
    def supported_protocols, do: [:grpc, :connect, :grpc_web]

    @impl true
    def validate_opts(opts, protocol) when is_list(opts) do
      with :ok <- validate_opts(opts), do: GRPC.Client.HTTPVersions.validate(protocol, opts)
    end

    @impl true
    def validate_opts(opts) when is_list(opts) do
      http2_opts = Keyword.get(opts, :http2_opts)

      with :ok <- validate_response_window(opts),
           :ok <- validate_stream_window(http2_opts) do
        validate_connection_window(http2_opts)
      end
    end

    defp validate_response_window(opts) do
      case Keyword.get(opts, :response_window, @default_response_window) do
        :infinity ->
          :ok

        window when is_integer(window) and window >= @min_response_window ->
          :ok

        other ->
          {:error,
           ":response_window must be :infinity or an integer of at least " <>
             "#{@min_response_window} bytes (one HTTP/2 frame), got: #{inspect(other)}"}
      end
    end

    # `:http2_opts` is a map, as Gun takes it. Gun checks its other keys.
    defp validate_stream_window(%{initial_stream_window_size: window}) do
      if is_integer(window) and window >= @min_response_window do
        :ok
      else
        {:error,
         "http2_opts :initial_stream_window_size must be an integer of at least " <>
           "#{@min_response_window} bytes (one HTTP/2 frame), got: #{inspect(window)}. " <>
           "A cowlib peer holds data back while the stream window is under " <>
           "#{@min_response_window} bytes and the data does not fit."}
      end
    end

    defp validate_stream_window(_http2_opts), do: :ok

    # cowlib subtracts 65,535, the protocol default of the connection window, in
    # `cow_http2_machine:common_preface/1`. `update_window/2` raises
    # `FunctionClauseError` for a smaller value.
    defp validate_connection_window(%{initial_connection_window_size: window}) do
      if is_integer(window) and window >= @min_connection_window do
        :ok
      else
        {:error,
         "http2_opts :initial_connection_window_size must be an integer of at least " <>
           "#{@min_connection_window} bytes (the HTTP/2 default), got: #{inspect(window)}. " <>
           "cowlib crashes when it opens a connection with a smaller value."}
      end
    end

    defp validate_connection_window(_http2_opts), do: :ok

    @impl true
    def connect(channel, opts) when is_list(opts) do
      # handle opts as a map due to :gun.open
      opts = Map.new(opts)

      case channel do
        %{scheme: "https"} -> connect_securely(channel, opts)
        _ -> connect_insecurely(channel, opts)
      end
    end

    defp connect_securely(%{cred: %{ssl: ssl}} = channel, opts) do
      transport_opts = Map.get(opts, :transport_opts) || []

      tls_opts = Keyword.merge(ssl, transport_opts)

      open_opts =
        opts
        |> Map.delete(:transport_opts)
        |> Map.merge(%{
          transport: :ssl,
          protocols: protocols(channel, opts, :tls),
          tcp_opts: @default_tcp_opts,
          tls_opts: tls_opts
        })

      do_connect(channel, open_opts)
    end

    defp connect_insecurely(channel, opts) do
      opts =
        Map.update(
          opts,
          :http2_opts,
          %{settings_timeout: :infinity},
          &Map.put(&1, :settings_timeout, :infinity)
        )

      transport_opts = Map.get(opts, :transport_opts) || []

      tcp_opts = Keyword.merge(@default_tcp_opts, transport_opts)

      open_opts =
        opts
        |> Map.delete(:transport_opts)
        |> Map.merge(%{
          transport: :tcp,
          protocols: protocols(channel, opts, :tcp),
          tcp_opts: tcp_opts
        })

      do_connect(channel, open_opts)
    end

    # See `GRPC.Client.HTTPVersions` for how the version is picked. The versions are named
    # `:http1` and `:http2` as the Mint adapter names them, Gun calls the first `:http`.
    defp protocols(%{protocol: protocol}, opts, transport) do
      protocol
      |> GRPC.Client.HTTPVersions.select(Map.get(opts, :protocols), transport)
      |> Enum.map(fn
        :http1 -> :http
        version -> version
      end)
    end

    defp do_connect(channel, open_opts) do
      # `:retry` and `:retry_fun` given in `:adapter_opts` take precedence.
      open_opts =
        %{retry: @max_retries, retry_fun: &__MODULE__.retry_fun/2}
        |> Map.merge(open_opts)
        |> Map.update(:http2_opts, %{notify_settings_changed: true}, fn opts ->
          Map.put(opts, :notify_settings_changed, true)
        end)
        |> put_response_window()

      case ConnectionProcess.connect(channel, open_opts) do
        {:ok, adapter_payload} ->
          {:ok, Map.put(channel, :adapter_payload, adapter_payload)}

        {:error, reason} ->
          {:error, reason}
      end
    end

    # Unless `:http2_opts` says otherwise, Gun's stream window is the response window.
    # Gun withholds the stream's WINDOW_UPDATE once the `flow` is used up, but the
    # peer may still fill what is left of the stream window.
    defp put_response_window(open_opts) do
      window = Map.get(open_opts, :response_window, @default_response_window)
      open_opts = Map.put(open_opts, :response_window, window)

      if window == :infinity do
        open_opts
      else
        Map.update!(open_opts, :http2_opts, &Map.put_new(&1, :initial_stream_window_size, window))
      end
    end

    @impl true
    def disconnect(%{adapter_payload: %{conn_pid: conn_pid}} = channel)
        when is_pid(conn_pid) do
      :ok = ConnectionProcess.disconnect(conn_pid)
      {:ok, %{channel | adapter_payload: %{conn_pid: nil}}}
    end

    def disconnect(%{adapter_payload: %{conn_pid: nil}} = channel) do
      {:ok, channel}
    end

    @impl true
    def send_request(stream, message, opts) do
      deadline = deadline(opts[:timeout])

      case do_send_request(stream, message, opts, deadline) do
        {:ok, stream_ref, response_pid} ->
          stream
          |> GRPC.Client.Stream.put_payload(:stream_ref, stream_ref)
          |> GRPC.Client.Stream.put_payload(:response_pid, response_pid)
          |> GRPC.Client.Stream.put_payload(:deadline, deadline)

        {:error, reason} ->
          put_request_error(stream, reason)
      end
    end

    defp do_send_request(
           %{channel: %{adapter_payload: %{conn_pid: conn_pid}}, path: path} = stream,
           message,
           opts,
           deadline
         ) do
      {method, path, headers, data} = request_parts(stream, path, message, opts)

      case call_connection(conn_pid, fn ->
             ConnectionProcess.request(conn_pid, method, path, headers, data, deadline)
           end) do
        {:ok, %{stream_ref: stream_ref, response_pid: response_pid}} ->
          {:ok, stream_ref, response_pid}

        {:error, reason} ->
          {:error, reason}
      end
    end

    # A Connect unary call sends its message as the whole body, or in the query of a GET.
    defp request_parts(%{channel: %{protocol: :connect}} = stream, path, message, opts) do
      kind = Connect.kind(stream)

      cond do
        opts[:http_method] == :get and kind == :unary ->
          {"GET", Connect.get_path(stream, message, opts), request_headers(stream, opts, "GET"),
           nil}

        kind == :unary ->
          {"POST", path, request_headers(stream, opts, "POST"),
           Connect.unary_body(message, opts[:compressor])}

        true ->
          {:ok, data, _} = GRPC.Message.to_data(message, opts)
          {"POST", path, request_headers(stream, opts, "POST"), data}
      end
    end

    defp request_parts(stream, path, message, opts) do
      {:ok, data, _} = GRPC.Message.to_data(message, opts)
      {"POST", path, request_headers(stream, opts, "POST"), data}
    end

    defp request_headers(%{channel: %{protocol: :connect}} = stream, opts, method),
      do: Connect.request_headers(stream, opts, method)

    defp request_headers(%{channel: %{protocol: :grpc_web}} = stream, opts, _method),
      do: GRPC.Client.GrpcWeb.request_headers(stream, opts)

    defp request_headers(stream, opts, _method),
      do: GRPC.Transport.HTTP2.client_headers_without_reserved(stream, opts)

    @impl true
    def send_headers(
          %{channel: %{adapter_payload: %{conn_pid: conn_pid}}, path: path} = stream,
          opts
        ) do
      deadline = deadline(opts[:timeout])
      headers = request_headers(stream, opts, "POST")

      case call_connection(conn_pid, fn ->
             ConnectionProcess.open_stream(conn_pid, path, headers, deadline)
           end) do
        {:ok, %{stream_ref: stream_ref, response_pid: response_pid}} ->
          stream
          |> GRPC.Client.Stream.put_payload(:stream_ref, stream_ref)
          |> GRPC.Client.Stream.put_payload(:response_pid, response_pid)
          |> GRPC.Client.Stream.put_payload(:deadline, deadline)

        {:error, reason} ->
          put_request_error(stream, reason)
      end
    end

    # A failed `send_request/3`, `send_headers/2` or `send_data/3` leaves the error
    # in the payload, and `receive_data/2` returns it.
    @impl true
    def send_data(%{payload: %{request_error: _}} = stream, _message, _opts), do: stream

    def send_data(%{channel: channel, payload: %{stream_ref: stream_ref}} = stream, message, opts) do
      conn_pid = channel.adapter_payload[:conn_pid]
      fin = if opts[:send_end_stream], do: :fin, else: :nofin
      {:ok, data, _} = GRPC.Message.to_data(message, opts)

      stream_data(stream, conn_pid, stream_ref, fin, data)
    end

    @impl true
    def end_stream(%{payload: %{request_error: _}} = stream), do: stream

    def end_stream(%{channel: channel, payload: %{stream_ref: stream_ref}} = stream) do
      conn_pid = channel.adapter_payload[:conn_pid]

      stream_data(stream, conn_pid, stream_ref, :fin, "")
    end

    defp stream_data(stream, conn_pid, stream_ref, fin, data) do
      case call_connection(conn_pid, fn ->
             ConnectionProcess.send_data(conn_pid, stream_ref, fin, data)
           end) do
        :ok -> stream
        {:error, reason} -> put_request_error(stream, reason)
      end
    end

    @impl true
    def cancel(%{payload: %{request_error: _}}), do: :ok

    def cancel(stream) do
      %{
        channel: %{adapter_payload: %{conn_pid: conn_pid}},
        payload: %{stream_ref: stream_ref}
      } = stream

      ConnectionProcess.cancel(conn_pid, stream_ref)
    end

    @impl true
    def receive_data(%{payload: %{request_error: error}}, _opts), do: {:error, error}

    def receive_data(%{channel: %{protocol: protocol}} = stream, opts)
        when protocol in [:connect, :grpc_web],
        do: receive_connect(stream, stream.grpc_type, opts)

    def receive_data(
          %{server_stream: true} = stream,
          opts
        ) do
      %{payload: payload} = stream
      deadline = receive_deadline(payload, opts)

      case recv_headers(payload, deadline) do
        {:ok, headers, :fin} ->
          handle_fin_response(headers, opts)

        {:ok, headers, :nofin} ->
          handle_streaming_nofin_response(stream, headers, opts, deadline)

        {:error, _} = error ->
          error
      end
    end

    def receive_data(stream, opts) do
      %{payload: payload} = stream
      deadline = receive_deadline(payload, opts)

      case recv_headers(payload, deadline) do
        {:ok, headers, :fin} ->
          # Trailers only: a status OK means the call returned no message.
          with :ok <- parse_trailers(headers, nil) do
            {:error, no_response_error(nil, headers)}
          end

        {:ok, headers, :nofin} ->
          handle_nofin_response(payload, stream, headers, opts, deadline)

        {:error, _} = error ->
          error
      end
    end

    # The Connect and gRPC-Web protocols. `Connect.Response` or `GrpcWeb.Response` reads the response, and this feeds it what
    # Gun delivers for the stream: the status and the headers, the data, the end.
    defp receive_connect(stream, type, opts)
         when type in [:server_stream, :bidirectional_stream] do
      state = connect_state(stream, opts)

      case connect_headers(state) do
        {:ok, headers, state} ->
          replies = connect_replies(state)

          if opts[:return_headers],
            do: {:ok, replies, %{headers: headers}},
            else: {:ok, replies}

        {:error, _} = error ->
          error
      end
    end

    defp receive_connect(stream, _type, opts) do
      {items, _state} = connect_collect(connect_state(stream, opts), [])

      case {Keyword.get(items, :error), Keyword.get_values(items, :ok)} do
        {nil, [reply]} ->
          if opts[:return_headers] do
            {:ok, reply,
             %{headers: Keyword.get(items, :headers), trailers: Keyword.get(items, :trailers)}}
          else
            {:ok, reply}
          end

        {nil, []} ->
          GRPC.Client.Telemetry.mark_rpc_failure(:remote, nil)

          {:error,
           GRPC.RPCError.exception(GRPC.Status.unimplemented(), "Missing response message.")}

        {nil, _several} ->
          GRPC.Client.Telemetry.mark_rpc_failure(:remote, nil)

          {:error,
           GRPC.RPCError.exception(
             GRPC.Status.unimplemented(),
             "Received more than one message for a call that returns one."
           )}

        {error, _replies} ->
          {:error, error}
      end
    end

    defp connect_state(stream, opts) do
      %{
        stream: stream,
        response: raw_response(stream),
        response_pid: stream.payload.response_pid,
        deadline: receive_deadline(stream.payload, opts),
        return_headers: opts[:return_headers] == true,
        items: [],
        done: false
      }
    end

    defp raw_response(%{channel: %{protocol: :connect}} = stream),
      do: GRPC.Client.Connect.Response.new(stream)

    defp raw_response(%{channel: %{protocol: :grpc_web}} = stream),
      do: GRPC.Client.GrpcWeb.Response.new(stream)

    # Reads up to the headers of the response. Whatever came with them stays in the state.
    defp connect_headers(%{items: [{:headers, headers} | rest]} = state),
      do: {:ok, headers, %{state | items: rest}}

    defp connect_headers(%{items: [{:error, error} | _]}), do: {:error, error}
    defp connect_headers(%{done: true}), do: {:error, connect_ended()}

    defp connect_headers(state) do
      case connect_pull(state) do
        {:error, _} = error -> error
        state -> connect_headers(state)
      end
    end

    # The replies of a streaming call are read from the response once, however many times
    # the caller enumerates them, as a caller does that reads a reply after each request of
    # a bidi stream. The state of the read is in an agent, linked to the caller, that goes
    # away with the last item.
    defp connect_replies(state) do
      {:ok, agent} = Agent.start_link(fn -> state end)
      Stream.resource(fn -> agent end, &connect_take/1, fn _agent -> :ok end)
    end

    defp connect_take(agent) do
      take = fn state ->
        case connect_next(state) do
          nil -> {:halt, state}
          {item, state} -> {{:item, item}, state}
        end
      end

      case Agent.get_and_update(agent, take, :infinity) do
        {:item, item} ->
          {[item], agent}

        :halt ->
          Agent.stop(agent)
          {:halt, agent}
      end
    catch
      :exit, _reason -> {:halt, agent}
    end

    # The next item of a streaming call. An error is the last one.
    defp connect_next(%{items: [{:error, error} | _]} = state) do
      unless state.done, do: cancel(state.stream)
      {{:error, error}, %{state | items: [], done: true}}
    end

    defp connect_next(%{items: [{:headers, _} | rest]} = state),
      do: connect_next(%{state | items: rest})

    defp connect_next(%{items: [{:trailers, _} | rest]} = state) when not state.return_headers,
      do: connect_next(%{state | items: rest})

    defp connect_next(%{items: [item | rest]} = state), do: {item, %{state | items: rest}}
    defp connect_next(%{done: true}), do: nil

    defp connect_next(state) do
      case connect_pull(state) do
        {:error, error} -> {{:error, error}, %{state | items: [], done: true}}
        state -> connect_next(state)
      end
    end

    # Reads the whole response: the items of the call by their kind.
    defp connect_collect(%{done: true} = state, acc), do: {acc ++ state.items, state}

    defp connect_collect(state, acc) do
      case connect_pull(state) do
        {:error, error} -> {acc ++ [error: error], state}
        pulled -> connect_collect(%{pulled | items: []}, acc ++ pulled.items)
      end
    end

    # Waits for the next thing Gun delivers and gives it to the response.
    defp connect_pull(%{response_pid: response_pid, deadline: deadline} = state) do
      case connect_events(response_pid, deadline) do
        {:error, _} = error ->
          error

        events ->
          Enum.reduce(events, state, fn event, state ->
            {response, items, action} =
              state.response.__struct__.consume(state.response, event)

            if action == :cancel, do: cancel(state.stream)

            %{
              state
              | response: response,
                items: state.items ++ items,
                done: state.done or event == :done or action == :cancel
            }
          end)
      end
    end

    defp connect_events(response_pid, deadline) do
      case GRPC.Client.Adapters.Gun.StreamResponseProcess.await(response_pid, deadline) do
        {:response, fin, status, headers} ->
          [{:status, status}, {:headers, headers}] ++ connect_end(fin)

        {:data, fin, data} ->
          [{:data, data}] ++ connect_end(fin)

        {:trailers, trailers} ->
          [{:headers, trailers}, :done]

        error ->
          {:error, error} = await_error(error, deadline)
          {:error, error}
      end
    end

    defp connect_end(:fin), do: [:done]
    defp connect_end(:nofin), do: []

    defp connect_ended,
      do: GRPC.RPCError.exception(GRPC.Status.internal(), "The response ended without headers")

    defp handle_fin_response(headers, opts) do
      # Trailers-only response: headers contain trailers, check status
      with :ok <- parse_trailers(headers, nil) do
        if opts[:return_headers] do
          {:ok, [], %{headers: headers}}
        else
          {:ok, []}
        end
      end
    end

    defp handle_streaming_nofin_response(stream, headers, opts, deadline) do
      compressor = get_compressor(headers, stream.accepted_compressors)
      response = response_stream(:nofin, stream, opts, deadline, compressor, headers)

      if opts[:return_headers] do
        {:ok, response, %{headers: headers}}
      else
        {:ok, response}
      end
    end

    defp handle_nofin_response(payload, stream, headers, opts, deadline) do
      # Regular response: fetch body and trailers
      with {:ok, body, trailers} <- recv_body(stream, payload, deadline),
           {:ok, response, embedded_trailers} <- parse_response(stream, headers, body, trailers) do
        if opts[:return_headers] do
          all_trailers = Map.merge(trailers, embedded_trailers)

          {
            :ok,
            response,
            %{headers: headers, trailers: all_trailers}
          }
        else
          {:ok, response}
        end
      end
    end

    defp recv_headers(%{response_pid: response_pid}, deadline) do
      case await(response_pid, deadline) do
        {:response, headers, fin} ->
          {:ok, headers, fin}

        {:error, _} = error ->
          error

        other ->
          {:error,
           GRPC.RPCError.exception(
             GRPC.Status.unknown(),
             "unexpected when waiting for headers: #{inspect(other)}"
           )}
      end
    end

    defp recv_data_or_trailers(%{response_pid: response_pid}, deadline) do
      case await(response_pid, deadline) do
        data = {:data, _} ->
          data

        data = {:data_fin, _} ->
          data

        trailers = {:trailers, _} ->
          trailers

        {:error, _} = error ->
          error

        other ->
          {:error,
           GRPC.RPCError.exception(
             GRPC.Status.unknown(),
             "unexpected when waiting for data: #{inspect(other)}"
           )}
      end
    end

    defp await(response_pid, deadline) do
      case GRPC.Client.Adapters.Gun.StreamResponseProcess.await(response_pid, deadline) do
        {:response, fin, status, headers} ->
          response_headers(status, headers, fin)

        {:data, :fin, data} ->
          {:data_fin, data}

        {:data, :nofin, data} ->
          {:data, data}

        trailers = {:trailers, _} ->
          trailers

        error ->
          await_error(error, deadline)
      end
    end

    defp await_error({:error, :timeout}, _deadline), do: deadline_exceeded()

    defp await_error({:error, :canceled}, _deadline) do
      {:error, GRPC.RPCError.exception(GRPC.Status.cancelled(), "Canceled by the client")}
    end

    # Connection-level failures are UNAVAILABLE per the gRPC status spec:
    # the RPC never completed on a live connection, so callers can safely
    # retry (deadline errors above stay DEADLINE_EXCEEDED).
    defp await_error({:error, {:connection_error, :closed}}, deadline)
         when is_integer(deadline) do
      if deadline <= System.monotonic_time(:millisecond) do
        deadline_exceeded()
      else
        connection_error(:closed)
      end
    end

    defp await_error({:error, {:connection_error, msg}}, _deadline), do: connection_error(msg)

    # A server enforces the `grpc-timeout` it was sent from when the request reached it,
    # so never before the client's own deadline. A CANCEL reset once the deadline has
    # passed is that deadline, whichever side notices first.
    defp await_error({:error, {:stream_error, msg}}, deadline) do
      if cancel_reset?(msg) and near_deadline?(deadline) do
        deadline_exceeded()
      else
        GRPC.Client.Telemetry.mark_rpc_failure(:after_dispatch, :stream_error)

        {:error, GRPC.RPCError.exception(GRPC.Status.internal(), "stream_error: #{inspect(msg)}")}
      end
    end

    # Gun's own way to report a gone connection, e.g. `{:down, :normal}`
    defp await_error({:error, {reason, msg}}, _deadline)
         when reason in [:down, :noproc, :normal, :shutdown] do
      connection_error({reason, msg})
    end

    defp await_error({:error, {reason, msg}}, _deadline) do
      {:error,
       GRPC.RPCError.exception(GRPC.Status.unknown(), "#{inspect(reason)}: #{inspect(msg)}")}
    end

    defp await_error(other, _deadline) do
      {:error,
       GRPC.RPCError.exception(
         GRPC.Status.unknown(),
         "unexpected message when waiting for server: #{inspect(other)}"
       )}
    end

    defp response_headers(200, headers, fin) do
      headers = GRPC.Transport.HTTP2.decode_headers(headers)

      if GRPC.Transport.HTTP2.grpc_content_type?(headers["content-type"]) do
        {:response, headers, fin}
      else
        {:error,
         GRPC.RPCError.exception(
           GRPC.Status.unknown(),
           "Unexpected content-type: #{inspect(headers["content-type"])}"
         )}
      end
    end

    defp response_headers(status, _headers, _fin) do
      {:error,
       GRPC.RPCError.exception(
         GRPC.Transport.HTTP2.status_from_http(status),
         "status got is #{status} instead of 200"
       )}
    end

    def retry_fun(retries, _opts) do
      curr = @max_retries - retries + 1

      timeout =
        if curr < 11 do
          :math.pow(1.6, curr - 1) * 1000
        else
          120_000
        end

      jitter =
        if function_exported?(:rand, :uniform_real, 0) do
          (:rand.uniform_real() - 0.5) / 2.5
        else
          (:rand.uniform() - 0.5) / 2.5
        end

      timeout = round(timeout + jitter * timeout)
      %{retries: retries - 1, timeout: timeout}
    end

    defp recv_body(stream, stream_payload, deadline) do
      recv_body(stream, stream_payload, [], 0, deadline)
    end

    defp recv_body(stream, stream_payload, acc, size, deadline) do
      case recv_data_or_trailers(stream_payload, deadline) do
        {:data, data} ->
          acc = [acc, data]
          new_size = size + byte_size(data)

          with :ok <- check_body_prefix(stream, acc, size, new_size) do
            recv_body(stream, stream_payload, acc, new_size, deadline)
          end

        # The last frame carried END_STREAM, so there are no trailers and no grpc-status.
        {:data_fin, data} ->
          {:ok, IO.iodata_to_binary([acc, data]), %{}}

        {:trailers, trailers} ->
          body = IO.iodata_to_binary(acc)
          {:ok, body, GRPC.Transport.HTTP2.decode_headers(trailers)}

        err ->
          err
      end
    end

    # Checks the length prefix in the chunk that completes it. A reply over
    # `:max_message_length` is not read to the end: the request is cancelled, which
    # resets the HTTP/2 stream, and the call fails with RESOURCE_EXHAUSTED. A codec
    # that packs the body for the channel (gRPC-web text) hides the prefix until the
    # whole body is unpacked, so it is checked later in `parse_response/4`.
    defp check_body_prefix(%{codec: codec} = stream, acc, size, new_size)
         when size < 5 and new_size >= 5 do
      if function_exported?(codec, :unpack_from_channel, 1) do
        :ok
      else
        limit = stream.max_receive_message_length

        case GRPC.Client.MessageLimit.check_prefix(IO.iodata_to_binary(acc), limit) do
          :ok ->
            :ok

          {:error, _} = error ->
            cancel(stream)
            error
        end
      end
    end

    defp check_body_prefix(_stream, _acc, _size, _new_size), do: :ok

    defp response_stream(
           :nofin,
           %{
             response_mod: res_mod,
             codec: codec,
             payload: payload
           } = stream,
           opts,
           deadline,
           compressor,
           headers
         ) do
      state = %{
        headers: headers,
        payload: payload,
        stream: stream,
        buffer: <<>>,
        fin: false,
        need_more: true,
        opts: opts,
        response_mod: res_mod,
        codec: codec,
        compressor: compressor,
        deadline: deadline,
        ended: false
      }

      Stream.unfold(state, fn s -> read_stream(s) end)
    end

    defp read_stream(%{buffer: <<>>, fin: true, fin_resp: nil}), do: nil

    defp read_stream(%{buffer: <<>>, fin: true, fin_resp: fin_resp} = s),
      do: {fin_resp, Map.put(s, :fin_resp, nil)}

    defp read_stream(
           %{
             payload: payload,
             buffer: buffer,
             need_more: true,
             opts: opts,
             deadline: deadline
           } = stream
         ) do
      case recv_data_or_trailers(payload, deadline) do
        {:data, data} ->
          stream
          |> Map.put(:need_more, false)
          |> Map.put(:buffer, buffer <> data)
          |> read_stream()

        {:data_fin, data} ->
          stream
          |> Map.put(:need_more, false)
          |> Map.put(:ended, true)
          |> Map.put(:buffer, buffer <> data)
          |> read_stream()

        {:trailers, trailers} ->
          update_stream_with_trailers(stream, trailers, opts[:return_headers])

        error = {:error, _} ->
          {error, %{buffer: <<>>, fin: true, fin_resp: nil}}
      end
    end

    defp read_stream(
           %{
             buffer: buffer,
             need_more: false,
             response_mod: res_mod,
             codec: codec,
             compressor: compressor,
             opts: opts,
             ended: ended
           } = stream
         ) do
      case get_message(buffer, compressor, stream.stream.max_receive_message_length) do
        {:error, _} = error ->
          # The rest of the message is not read: reset the stream.
          cancel(stream.stream)
          {error, %{buffer: <<>>, fin: true, fin_resp: nil}}

        {{:trailers, trailers}, rest} ->
          new_stream =
            stream
            |> update_stream_with_trailers(trailers, opts[:return_headers])
            |> Map.put(:buffer, rest)

          {{:ok, trailers}, new_stream}

        {{_, message}, rest} ->
          case GRPC.Client.ReplyDecoder.decode(codec, message, res_mod) do
            {:ok, reply} ->
              {{:ok, reply}, Map.put(stream, :buffer, rest)}

            {:error, error} ->
              cancel(stream.stream)
              {{:error, error}, %{buffer: <<>>, fin: true, fin_resp: nil}}
          end

        _ when ended ->
          # The stream ended without a `grpc-status`.
          error = %{missing_status_error(buffer) | headers: stream.headers}
          {{:error, error}, %{buffer: <<>>, fin: true, fin_resp: nil}}

        _ ->
          read_stream(Map.put(stream, :need_more, true))
      end
    end

    defp missing_status_error(<<>>) do
      GRPC.Client.Telemetry.mark_rpc_failure(:remote, nil)

      GRPC.RPCError.exception(GRPC.Status.internal(), "Missing grpc-status in the response.")
    end

    defp missing_status_error(_incomplete_message) do
      GRPC.Client.Telemetry.mark_rpc_failure(:remote, nil)

      GRPC.RPCError.exception(
        GRPC.Status.internal(),
        "The response ended in the middle of a message."
      )
    end

    # A message over `:max_message_length` ends the stream with an error item.
    # The prefix is checked here, as newer `GRPC.Message.get_message/1` does, and
    # that function raises for it.
    defp get_message(buffer, compressor, limit) do
      with :ok <- GRPC.Client.MessageLimit.check_prefix(buffer, limit) do
        case GRPC.Message.get_message(buffer, compressor, max_message_length: limit) do
          {{1, _message}, _rest} when is_nil(compressor) ->
            {:error,
             GRPC.RPCError.exception(
               status: :internal,
               message: "Compressed flag is set, but not specified in headers."
             )}

          other ->
            other
        end
      end
    rescue
      error in GRPC.RPCError ->
        {:error, error}

      _ ->
        {:error,
         GRPC.RPCError.exception(status: :internal, message: "Message could not be decompressed.")}
    end

    defp cancel_reset?({:stream_error, :cancel, _}), do: true
    defp cancel_reset?(_), do: false

    defp near_deadline?(deadline) when is_integer(deadline),
      do: deadline - @deadline_tolerance <= System.monotonic_time(:millisecond)

    defp near_deadline?(_), do: false

    defp deadline(nil), do: :infinity
    defp deadline(:infinity), do: :infinity

    defp deadline(timeout) when is_integer(timeout),
      do: System.monotonic_time(:millisecond) + max(timeout, 0)

    defp receive_deadline(payload, opts) do
      earlier_deadline(Map.get(payload, :deadline, :infinity), deadline(opts[:timeout]))
    end

    defp earlier_deadline(:infinity, deadline), do: deadline
    defp earlier_deadline(deadline, :infinity), do: deadline
    defp earlier_deadline(left, right), do: min(left, right)

    defp deadline_exceeded do
      GRPC.Client.Telemetry.mark_rpc_failure(:after_dispatch, :deadline)

      {:error,
       GRPC.RPCError.exception(
         GRPC.Status.deadline_exceeded(),
         "Deadline expired"
       )}
    end

    defp connection_error(msg) do
      GRPC.Client.Telemetry.mark_rpc_failure(:after_dispatch, :connection_unavailable)

      {:error,
       GRPC.RPCError.exception(
         GRPC.Status.unavailable(),
         "connection_error: #{inspect(msg)}"
       )}
    end

    # Calls the connection process and turns a dead or missing one into
    # `{:error, reason}`. The exit reason of a request call carries its headers, so
    # it goes through `Adapter.redact/1` before it is kept. A call timeout still exits.
    defp call_connection(nil, _fun), do: {:error, :disconnected}

    defp call_connection(_conn_pid, fun) do
      fun.()
    catch
      :exit, {:timeout, _} = reason ->
        :erlang.raise(:exit, reason, __STACKTRACE__)

      :exit, reason ->
        case Adapter.redact(reason) do
          {reason, {GenServer, :call, _}} -> {:error, reason}
          reason -> {:error, reason}
        end
    end

    defp put_request_error(stream, reason) do
      GRPC.Client.Telemetry.mark_rpc_failure(:local_pre_send, :connection_unavailable)

      error =
        GRPC.RPCError.exception(
          GRPC.Status.unavailable(),
          "connection_error: #{inspect(reason)}"
        )

      GRPC.Client.Stream.put_payload(stream, :request_error, error)
    end

    defp parse_response(
           %{
             response_mod: res_mod,
             codec: codec,
             accepted_compressors: accepted_compressors,
             max_receive_message_length: limit
           },
           headers,
           body,
           trailers
         ) do
      with :ok <- parse_trailers(trailers, headers),
           compressor <- get_compressor(headers, accepted_compressors),
           body <- get_body(codec, body),
           :ok <- check_has_message(body, headers, trailers),
           :ok <- GRPC.Client.MessageLimit.check_prefix(body, limit),
           {:ok, msg, remaining} <-
             GRPC.Message.from_data(%{compressor: compressor, max_message_length: limit}, body),
           {:ok, embedded_trailers} <- check_for_trailers(remaining, compressor),
           {:ok, reply} <- GRPC.Client.ReplyDecoder.decode(codec, msg, res_mod) do
        {:ok, reply, embedded_trailers}
      end
    end

    # A call that returns one message did not, though its status is OK.
    defp check_has_message(<<>>, headers, trailers),
      do: {:error, no_response_error(headers, trailers)}

    defp check_has_message(_body, _headers, _trailers), do: :ok

    defp no_response_error(headers, trailers) do
      error =
        GRPC.RPCError.exception(GRPC.Status.unimplemented(), "Missing response message.")

      %{error | headers: headers, trailers: trailers}
    end

    defp check_for_trailers(<<>>, _compressor), do: {:ok, %{}}

    defp check_for_trailers(body, compressor) do
      case GRPC.Message.from_data(%{compressor: compressor}, body) do
        {:trailers, trailers, <<>>} ->
          {:ok, trailers}

        _ when binary_part(body, 0, 1) == <<128>> ->
          # A trailers frame that cannot be read: the status is checked elsewhere.
          {:ok, %{}}

        _ ->
          {:error,
           GRPC.RPCError.exception(
             GRPC.Status.unimplemented(),
             "Received more than one message for a call that returns one."
           )}
      end
    end

    defp update_stream_with_trailers(stream, trailers, return_headers?) do
      trailers = GRPC.Transport.HTTP2.decode_headers(trailers)

      case parse_trailers(trailers, stream.headers) do
        :ok ->
          fin_resp = if return_headers?, do: {:trailers, trailers}

          stream
          |> Map.put(:fin, true)
          |> Map.put(:fin_resp, fin_resp)
          |> Map.put(:ended, true)
          |> Map.put(:need_more, false)
          |> read_stream()

        error ->
          {error, %{buffer: <<>>, fin: true, fin_resp: nil}}
      end
    end

    # The error carries the response headers and the trailers it came from.
    defp parse_trailers(trailers, headers) do
      case check_trailers(trailers) do
        :ok -> :ok
        {:error, error} -> {:error, %{error | headers: headers, trailers: trailers}}
      end
    end

    defp check_trailers(%{"grpc-status" => value} = trailers) do
      case Integer.parse(value) do
        {status, ""} ->
          parse_status(status, trailers)

        _ ->
          {:error, GRPC.RPCError.exception(GRPC.Status.internal(), "Invalid grpc-status.")}
      end
    end

    defp check_trailers(_trailers), do: {:error, missing_status_error(<<>>)}

    defp parse_status(status, trailers) do
      if status == GRPC.Status.ok() do
        :ok
      else
        rpc_error =
          GRPC.RPCError.from_grpc_status_details_bin(%{
            status: status,
            message: trailers["grpc-message"],
            encoded_details_bin: trailers["grpc-status-details-bin"]
          })

        GRPC.Client.Telemetry.mark_rpc_failure(:remote, nil)
        {:error, rpc_error}
      end
    end

    defp get_compressor(%{"grpc-encoding" => encoding} = _headers, accepted_compressors) do
      Enum.find(accepted_compressors, nil, fn c -> c.name() == encoding end)
    end

    defp get_compressor(_headers, _accepted_compressors), do: nil

    defp get_body(codec, body) do
      if function_exported?(codec, :unpack_from_channel, 1) do
        codec.unpack_from_channel(body)
      else
        body
      end
    end
  end
end
