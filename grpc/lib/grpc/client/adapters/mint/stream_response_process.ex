defmodule GRPC.Client.Adapters.Mint.StreamResponseProcess do
  @moduledoc false
  # This module represents the process responsible for consuming the
  # incoming messages from a connection. For each request, there will be
  # a process responsible for consuming its messages. At the end of a stream
  # this process will automatically be killed.
  #
  # ## Buffer draining
  #
  # A single HTTP/2 data frame may carry more than one complete gRPC message.
  # Whenever a `:data` chunk arrives, the process concatenates it with any
  # previously buffered bytes and then calls `drain_buffer/5` to decode *all*
  # complete messages in one pass before returning control. Only the incomplete
  # tail (if any) is kept in the buffer for the next chunk. This prevents
  # consumers from blocking on `:get_response` when the data is already
  # available inside the process.
  #
  # TODO: Refactor the GenServer.call/3 occurrences on this module to produce
  # telemetry events in case of failures

  @accepted_types [:data, :trailers, :headers, :error, :status]
  @connect_events [:status, :headers, :trailers, :data]
  @header_types [:headers, :trailers]

  use GenServer

  def start_link(stream, send_headers_or_trailers?) do
    GenServer.start_link(__MODULE__, {stream, send_headers_or_trailers?})
  end

  @doc """
  Given a pid from this process, build an Elixir.Stream that will consume the accumulated
  data inside this process.

  `timeout` bounds how long the stream waits for each response. When it elapses
  the stream emits `{:error, :deadline_exceeded}` and halts, rather than waiting
  for a response that may never arrive — the connection process notifies this
  process, so anything that stops it from doing so (a connection that goes down
  without cleaning up, for instance) would otherwise block the caller forever.
  `{:deadline, at}`, with `at` a `System.monotonic_time(:millisecond)` instant, bounds
  the whole stream instead: each wait lasts until then.
  Defaults to `:infinity` to keep the previous behaviour for callers that do not
  ask for a deadline.
  """
  def build_stream(pid, produce_trailers? \\ true, timeout \\ :infinity) do
    Stream.unfold(pid, fn
      :halt ->
        nil

      pid ->
        pid
        |> get_response(timeout)
        |> process_response(produce_trailers?, pid, timeout)
    end)
  end

  defp get_response(pid, {:deadline, at}) do
    get_response(pid, max(at - System.monotonic_time(:millisecond), 0))
  end

  defp get_response(pid, timeout) do
    GenServer.call(pid, :get_response, timeout)
  catch
    :exit, {:timeout, {GenServer, :call, _args}} -> :deadline_exceeded
  end

  defp process_response(nil = _response, _produce_trailers, _pid, _timeout), do: nil

  defp process_response(:deadline_exceeded, _produce_trailers, _pid, _timeout) do
    {{:error, :deadline_exceeded}, :halt}
  end

  defp process_response({:trailers, _trailers}, false = produce_trailers?, pid, timeout) do
    pid
    |> get_response(timeout)
    |> process_response(produce_trailers?, pid, timeout)
  end

  defp process_response(response, _produce_trailers, pid, _timeout) do
    {response, pid}
  end

  @doc """
  Cast a message to process to inform that the stream has finished
    once all messages are produced. This process will automatically
    be killed.

  Returns `:ok`, or `{:error, reason}` when the stream response process
  is no longer alive (e.g. the caller gave up on the request).
  """
  def done(pid) do
    GenServer.call(pid, {:consume_response, :done})
  catch
    :exit, {reason, {GenServer, :call, _args}} -> {:error, reason}
  end

  @doc """
  Ends the response because the caller cancelled the request. Unlike `done/1`,
  a response that has no `grpc-status` is not an error here.
  """
  def cancel(pid) do
    GenServer.call(pid, {:consume_response, :cancel})
  catch
    :exit, {reason, {GenServer, :call, _args}} -> {:error, reason}
  end

  @doc """
  Consume an incoming data or trailers/headers.

  Returns `:ok`, `:cancel` when the request should be reset because the
  response is over the message size limit, or `{:error, reason}` when the stream
  response process is no longer alive (e.g. the caller gave up on the request).
  """
  def consume(pid, type, data) when type in @accepted_types do
    GenServer.call(pid, {:consume_response, {type, data}})
  catch
    :exit, {reason, {GenServer, :call, _args}} -> {:error, reason}
  end

  # Callbacks

  @impl true
  def init({stream, send_headers_or_trailers?}) do
    state = %{
      grpc_stream: stream,
      send_headers_or_trailers: send_headers_or_trailers?,
      buffer: <<>>,
      responses: :queue.new(),
      done: false,
      from: nil,
      compressor: nil,
      failed: false,
      # An error status in the first headers, which counts only if the response
      # ends right there (a trailers-only response). Trailers replace it, and a
      # message after it makes the missing trailers the error.
      pending_status: nil,
      data_seen: false,
      # The response ended with a `grpc-status`, or with an error, so it is complete.
      terminated: false,
      # The state of a Connect response, which has no `grpc-status`.
      connect: connect_response(stream)
    }

    {:ok, state}
  end

  defp connect_response(%{channel: %{protocol: :connect}} = stream),
    do: GRPC.Client.Connect.Response.new(stream)

  defp connect_response(_stream), do: nil

  @impl true
  def handle_call(:get_response, from, state) do
    {:noreply, put_in(state[:from], from), {:continue, :produce_response}}
  end

  def handle_call({:consume_response, event}, _from, %{connect: connect} = state)
      when connect != nil and
             (event == :done or (is_tuple(event) and elem(event, 0) in @connect_events)) do
    if state.failed do
      {:reply, :cancel, state, {:continue, :produce_response}}
    else
      {connect, items, action} = GRPC.Client.Connect.Response.consume(connect, event)
      state = %{state | connect: connect}
      state = Enum.reduce(items, state, &queue_connect_item/2)

      case {action, event} do
        # The response cannot be read any further: the request is reset.
        {:cancel, _} ->
          state = %{state | failed: true, terminated: true, done: true}
          {:reply, :cancel, state, {:continue, :produce_response}}

        {:ok, :done} ->
          {:reply, :ok, %{state | terminated: true, done: true}, {:continue, :produce_response}}

        {:ok, _} ->
          {:reply, :ok, state, {:continue, :produce_response}}
      end
    end
  end

  # After a message over the size limit the rest of the body can't be framed
  # any more, so it is dropped, and the connection process is told to cancel again.
  def handle_call({:consume_response, {:data, _data}}, _from, %{failed: true} = state) do
    {:reply, :cancel, state, {:continue, :produce_response}}
  end

  def handle_call({:consume_response, {:data, data}}, _from, state) do
    %{
      buffer: buffer,
      grpc_stream: %{response_mod: res_mod, codec: codec},
      responses: responses
    } = state

    # Concatenate once and fully drain all complete gRPC messages from the
    # combined buffer in a single pass, avoiding repeated allocation and
    # preventing consumers from blocking when multiple messages arrive in
    # the same HTTP/2 data frame.
    combined = buffer <> data

    case drain_buffer(combined, state.compressor, codec, res_mod, responses) do
      {new_buffer, new_responses} ->
        new_state =
          %{state | buffer: new_buffer, responses: new_responses} |> Map.put(:data_seen, true)

        {:reply, :ok, new_state, {:continue, :produce_response}}

      # The error ends the stream, and the reply `:cancel` asks the connection
      # process to reset the request, so no more of the message is sent. It then
      # sends nothing else for this request, so `done` is set here.
      {:error, error, new_responses} ->
        new_state = %{
          state
          | buffer: <<>>,
            responses: :queue.in({:error, error}, new_responses),
            failed: true,
            terminated: true,
            done: true
        }

        {:reply, :cancel, new_state, {:continue, :produce_response}}
    end
  end

  def handle_call({:consume_response, {type, headers}}, _from, state)
      when type in @header_types do
    {:reply, :ok, consume_headers(type, headers, state), {:continue, :produce_response}}
  end

  # A late error does not replace a response that has ended.
  def handle_call({:consume_response, {:error, _error}}, _from, %{done: true} = state) do
    {:reply, :ok, state, {:continue, :produce_response}}
  end

  def handle_call(
        {:consume_response, {:error, _error} = error},
        _from,
        %{responses: responses} = state
      ) do
    # An error ends the stream: the request is reset after it, so no `:done` follows.
    {:reply, :ok, %{state | responses: :queue.in(error, responses), terminated: true, done: true},
     {:continue, :produce_response}}
  end

  # The headers carried the status and nothing followed: a trailers-only response.
  def handle_call(
        {:consume_response, :done},
        _from,
        %{pending_status: {:error, _} = error, terminated: false} = state
      )
      when not is_map_key(state, :data_seen) or state.data_seen != true do
    {:reply, :ok,
     %{state | responses: :queue.in(error, state.responses), terminated: true, done: true},
     {:continue, :produce_response}}
  end

  # The stream ended. Without a `grpc-status` or an error the call did not complete.
  def handle_call({:consume_response, :done}, _from, %{terminated: false} = state) do
    error = {:error, %{missing_status_error(state.buffer) | headers: Map.get(state, :headers)}}
    responses = :queue.in(error, state.responses)

    {:reply, :ok, %{state | responses: responses, terminated: true, done: true},
     {:continue, :produce_response}}
  end

  # The trailers came while a message was still incomplete.
  def handle_call(
        {:consume_response, :done},
        _from,
        %{terminated: :status, buffer: buffer} = state
      )
      when buffer != <<>> do
    error = {:error, %{missing_status_error(buffer) | headers: Map.get(state, :headers)}}
    responses = :queue.in(error, state.responses)

    {:reply, :ok, %{state | responses: responses, terminated: true, done: true},
     {:continue, :produce_response}}
  end

  def handle_call({:consume_response, :cancel}, _from, state) do
    canceled =
      {:error, GRPC.RPCError.exception(GRPC.Status.cancelled(), "Canceled by the client")}

    {:reply, :ok,
     %{state | responses: :queue.in(canceled, state.responses), terminated: true, done: true},
     {:continue, :produce_response}}
  end

  def handle_call({:consume_response, :done}, _from, state) do
    {:reply, :ok, %{state | done: true}, {:continue, :produce_response}}
  end

  @impl true
  def handle_continue(:produce_response, state) do
    no_responses? = :queue.is_empty(state.responses)
    without_from? = is_nil(state.from)

    cond do
      without_from? ->
        {:noreply, state}

      no_responses? and state.done ->
        GenServer.reply(state.from, nil)
        {:stop, :normal, state}

      no_responses? ->
        {:noreply, state}

      true ->
        {{:value, response}, rest} = :queue.out(state.responses)
        GenServer.reply(state.from, response)
        {:noreply, %{state | responses: rest, from: nil}}
    end
  end

  # The headers and trailers of a response are produced only when the caller wants them.
  defp queue_connect_item({type, _} = item, state) when type in @header_types do
    if state.send_headers_or_trailers,
      do: %{state | responses: :queue.in(item, state.responses)},
      else: state
  end

  defp queue_connect_item({:error, _} = item, state),
    do: %{state | responses: :queue.in(item, state.responses), terminated: true}

  defp queue_connect_item(item, state),
    do: %{state | responses: :queue.in(item, state.responses)}

  defp consume_headers(:headers, headers, %{terminated: false} = state) do
    case get_headers_response(headers, :headers, nil) do
      {:error, _error} = error ->
        state = update_compressor({:headers, headers}, state)

        state
        |> Map.put(:pending_status, error)
        |> Map.put(:headers, GRPC.Transport.HTTP2.decode_headers(headers))

      _response ->
        do_consume_headers(:headers, headers, state)
    end
  end

  defp consume_headers(type, headers, state),
    do: do_consume_headers(type, headers, Map.put(state, :pending_status, nil))

  defp do_consume_headers(type, headers, %{send_headers_or_trailers: true} = state) do
    state = update_compressor({type, headers}, state)
    response = get_headers_response(headers, type, response_headers_for(type, state))
    state = remember_headers(response, state)

    %{
      state
      | responses: :queue.in(response, state.responses),
        terminated: state.terminated || terminal?(response)
    }
  end

  defp do_consume_headers(type, headers, state) do
    state = update_compressor({type, headers}, state)
    response = get_headers_response(headers, type, response_headers_for(type, state))
    state = remember_headers(response, state)
    state = %{state | terminated: state.terminated || terminal?(response)}

    case response do
      {:error, _rpc_error} = error -> %{state | responses: :queue.in(error, state.responses)}
      _any -> state
    end
  end

  # Recursively decodes all complete gRPC messages from `buffer`, accumulating
  # each decoded response into `responses_queue`. Recursion terminates when
  # `GRPC.Message.get_message/2` can no longer extract a full message from the
  # remaining bytes, at which point the leftover buffer and the populated queue
  # are returned as `{remaining_buffer, updated_queue}`. A message over the size
  # limit ends the pass with `{:error, error, updated_queue}`.
  defp drain_buffer(buffer, compressor, codec, res_mod, responses_queue) do
    case get_message(buffer, compressor) do
      {:error, error} ->
        {:error, error, responses_queue}

      {{_, message}, rest} ->
        # TODO: add code here to handle compressor headers
        case GRPC.Client.ReplyDecoder.decode(codec, message, res_mod) do
          {:ok, response} ->
            drain_buffer(
              rest,
              compressor,
              codec,
              res_mod,
              :queue.in({:ok, response}, responses_queue)
            )

          {:error, error} ->
            {:error, error, responses_queue}
        end

      _ ->
        {buffer, responses_queue}
    end
  end

  # The prefix is checked here, as newer `GRPC.Message.get_message/2` does, and
  # that function raises for a message over `:max_message_length` or a gzip bomb.
  defp get_message(buffer, compressor) do
    with :ok <- GRPC.Client.MessageLimit.check_prefix(buffer) do
      case GRPC.Message.get_message(buffer, compressor) do
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
    error in GRPC.RPCError -> {:error, error}
  end

  defp get_headers_response(headers, type, response_headers) do
    decoded_trailers = GRPC.Transport.HTTP2.decode_headers(headers)

    case parse_status(decoded_trailers["grpc-status"]) do
      nil when type == :trailers ->
        {:error, with_metadata(missing_status_error(<<>>), response_headers, decoded_trailers)}

      nil ->
        {type, decoded_trailers}

      :error ->
        {:error,
         with_metadata(
           GRPC.RPCError.exception(GRPC.Status.internal(), "Invalid grpc-status."),
           response_headers,
           decoded_trailers
         )}

      status ->
        if status == GRPC.Status.ok() do
          {type, decoded_trailers}
        else
          rpc_error =
            GRPC.RPCError.from_grpc_status_details_bin(%{
              status: status,
              message: decoded_trailers["grpc-message"],
              encoded_details_bin: decoded_trailers["grpc-status-details-bin"]
            })

          {:error, with_metadata(rpc_error, response_headers, decoded_trailers)}
        end
    end
  end

  # The headers of a response that has started go with an error from its trailers.
  defp response_headers_for(:trailers, state), do: Map.get(state, :headers)
  defp response_headers_for(_type, _state), do: nil

  defp with_metadata(error, headers, trailers),
    do: %{error | headers: headers, trailers: trailers}

  defp remember_headers({:headers, headers}, state), do: Map.put(state, :headers, headers)
  defp remember_headers(_response, state), do: state

  defp parse_status(nil), do: nil

  defp parse_status(value) do
    case Integer.parse(value) do
      {status, ""} -> status
      _ -> :error
    end
  end

  # An error, or headers carrying a `grpc-status`, end the response.
  defp terminal?({:error, _}), do: true
  defp terminal?({_type, %{"grpc-status" => _}}), do: :status
  defp terminal?(_response), do: false

  defp missing_status_error(<<>>) do
    GRPC.RPCError.exception(GRPC.Status.internal(), "Missing grpc-status in the response.")
  end

  defp missing_status_error(_incomplete_message) do
    GRPC.RPCError.exception(
      GRPC.Status.internal(),
      "The response ended in the middle of a message."
    )
  end

  defp update_compressor({:headers, headers}, state) do
    decoded_trailers = GRPC.Transport.HTTP2.decode_headers(headers)

    compressor =
      get_compressor(decoded_trailers["grpc-encoding"], state.grpc_stream.accepted_compressors)

    %{state | compressor: compressor}
  end

  defp update_compressor(_headers, state), do: state

  defp get_compressor(nil = _encoding_name, _accepted_compressors), do: nil

  defp get_compressor(encoding_name, accepted_compressors) do
    Enum.find(accepted_compressors, nil, fn c -> c.name() == encoding_name end)
  end

  @impl true
  def terminate(_reason, _state) do
    :normal
  end
end
