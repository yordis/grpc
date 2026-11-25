if Code.ensure_loaded?(:gun) do
  defmodule GRPC.Client.Adapters.Gun.ConnectionProcess do
    @moduledoc """
    Owns long-lived Gun connections on behalf of the Gun adapter.

    This process exists so named Gun-backed channels are no longer tied to the
    lifecycle of the process that happened to call `GRPC.Stub.connect/2`.

    Without this wrapper, `GRPC.Client.Connection` would need to own Gun directly
    or understand Gun-specific owner messages. Keeping Gun ownership in this
    adapter-local process preserves a clean adapter boundary while ensuring the
    underlying Gun connection survives short-lived callers.

    Request-specific Gun messages are routed to per-stream response processes, so
    this process only needs to manage connection-level lifecycle and stream
    bookkeeping.

    Named channels are registered in the node-local `GRPC.Client.Registry` under
    `{ref, host, port}`, so a connection is reused by every caller on the node.

    The handshake runs after `init/1` returns, and `connect/2` waits for it
    outside the node-wide `GRPC.Client.Supervisor`. A slow or unreachable host
    therefore doesn't hold up connects to other hosts.
    """

    use GenServer

    @deadline_cancel_grace_ms 100
    @default_await_timeout 5_000
    # Extra time for the call on top of `:await_timeout`. The connection process
    # replies by the time its own timer fires, so this only covers scheduling.
    @await_up_call_margin_ms 1_000
    # Gun counts a stream's `flow` in DATA frames, and a peer sends at most
    # 16 KiB per frame unless the local settings raise it.
    @frame_size 16_384

    require Logger
    alias GRPC.Client.Adapter
    alias GRPC.Client.HTTP1Lanes
    alias GRPC.Client.Adapters.Gun.StreamResponseProcess
    alias GRPC.Client.Telemetry

    def connect(channel, open_opts) when is_map(open_opts) do
      case DynamicSupervisor.start_child(GRPC.Client.Supervisor, child_spec(channel, open_opts)) do
        {:ok, connection_process_pid} ->
          await_up(connection_process_pid, open_opts)

        {:error, {:already_started, connection_process_pid}} ->
          await_up(connection_process_pid, open_opts)

        {:error, reason} ->
          {:error, reason}
      end
    end

    defp await_up(connection_process_pid, open_opts) do
      timeout =
        Map.get(open_opts, :await_timeout, @default_await_timeout) + @await_up_call_margin_ms

      case GenServer.call(connection_process_pid, :await_up, timeout) do
        :ok -> {:ok, %{conn_pid: connection_process_pid}}
        {:error, reason} -> {:error, reason}
      end
    catch
      :exit, {reason, {GenServer, :call, _}} -> {:error, reason}
    end

    def disconnect(connection_process_pid) when is_pid(connection_process_pid) do
      GenServer.call(connection_process_pid, :disconnect)
    catch
      :exit, _reason ->
        :ok
    end

    # Calls carrying headers or bodies go through `Adapter.call/3`, so an exit (busy or dead
    # connection process) does not leak them into logs and telemetry.
    def request(connection_process_pid, path, headers, body, deadline \\ :infinity) do
      request(connection_process_pid, "POST", path, headers, body, deadline, [])
    end

    # A request without a body, such as a Connect GET, has `nil` as the body.
    # `opts[:cancel]` is the cancel handle of the call. A call that waits for a connection
    # of the channel stops waiting when it is cancelled or its deadline passes.
    def request(connection_process_pid, method, path, headers, body, deadline, opts \\ []) do
      request = {:request, method, path, headers, body, deadline}

      connection_process_pid
      |> Adapter.call(request)
      |> on_lane(connection_process_pid, request, opts)
    end

    def open_stream(connection_process_pid, path, headers, deadline \\ :infinity, opts \\ []) do
      request = {:open_stream, path, headers, deadline}

      connection_process_pid
      |> Adapter.call(request)
      |> on_lane(connection_process_pid, request, opts)
    end

    # HTTP/1.1 carries one request at a time on a connection. A call that finds the
    # connection busy gets a connection of its own, for that one call. The reply
    # carries the pid that holds the stream, and the data, cancel and deadline calls
    # go to it.
    defp on_lane({:busy, {channel, open_opts}}, pid, request, opts) do
      with {:ok, token} <- acquire_lane(pid, request, opts) do
        case GenServer.start(__MODULE__, {channel, Map.put(open_opts, :lane?, true)}) do
          {:ok, lane} ->
            try do
              timeout =
                Map.get(open_opts, :await_timeout, @default_await_timeout) +
                  @await_up_call_margin_ms

              with :ok <- HTTP1Lanes.attach(pid, token, lane),
                   :ok <- GenServer.call(lane, :await_up, timeout),
                   {:ok, response} <- Adapter.call(lane, request) do
                {:ok, Map.put(response, :conn_pid, lane)}
              else
                {:error, _reason} = error ->
                  stop_lane(lane)
                  error
              end
            catch
              :exit, reason ->
                stop_lane(lane)
                :erlang.raise(:exit, reason, __STACKTRACE__)
            end

          {:error, reason} ->
            HTTP1Lanes.release(pid, token)
            {:error, reason}
        end
      end
    end

    defp on_lane(reply, _pid, _request, _opts), do: reply

    defp acquire_lane(pid, request, opts) do
      deadline = elem(request, tuple_size(request) - 1)
      deadline = if is_integer(deadline), do: deadline

      HTTP1Lanes.acquire(pid, deadline: deadline, cancel: opts[:cancel])
    end

    defp stop_lane(lane) do
      GenServer.stop(lane, :normal, 1_000)
    catch
      :exit, _reason -> :ok
    end

    def send_data(connection_process_pid, stream_ref, fin, data) do
      Adapter.call(connection_process_pid, {:send_data, stream_ref, fin, data})
    end

    # A dead connection process has nothing left to cancel.
    def cancel(connection_process_pid, stream_ref) do
      GenServer.call(connection_process_pid, {:cancel, stream_ref})
    catch
      :exit, _reason -> :ok
    end

    defp child_spec(channel, open_opts) do
      %{
        id: {__MODULE__, owner_key(channel)},
        start: {__MODULE__, :start_link, [channel, open_opts]},
        restart: :temporary,
        type: :worker,
        shutdown: 5000
      }
    end

    def start_link(channel, open_opts) do
      if is_nil(channel.ref) do
        GenServer.start_link(__MODULE__, {channel, open_opts})
      else
        GenServer.start_link(__MODULE__, {channel, open_opts}, name: via(channel))
      end
    end

    @impl GenServer
    def init({%{host: host, port: port} = channel, open_opts}) do
      {lane?, open_opts} = Map.pop(open_opts, :lane?, false)
      spec = {channel, open_opts}
      # Pooled connections open with `ref: nil`, so the pool passes the logical ref separately
      {logical_ref, open_opts} = Map.pop(open_opts, :logical_connection_ref, channel.ref)
      metadata = metadata(channel, logical_ref)
      unless lane?, do: Telemetry.execute(:started, %{generation: 0, active_streams: 0}, metadata)

      {max_http1, open_opts} =
        Map.pop(open_opts, :http1_max_connections, HTTP1Lanes.default_max_connections())

      {await_timeout, open_opts} = Map.pop(open_opts, :await_timeout, @default_await_timeout)
      {response_window, open_opts} = Map.pop(open_opts, :response_window, :infinity)

      case open(host, port, open_opts) do
        {:ok, gun_pid} ->
          # Monitor Gun so we don't keep casting into a dead pid if Gun
          # exhausts its reconnect retries (or crashes)
          Process.monitor(gun_pid)

          {:ok,
           %{
             channel: channel,
             logical_connection_ref: logical_ref,
             lane?: lane?,
             lanes: HTTP1Lanes.new(max_http1),
             served?: false,
             http1?: false,
             spec: spec,
             gun_open_opts: open_opts,
             await_timeout: await_timeout,
             gun_pid: gun_pid,
             flow: window_to_flow(response_window),
             response_processes: %{},
             generation: 0,
             max_concurrent_streams: :unknown,
             status: :connecting,
             waiters: [],
             await_timer: Process.send_after(self(), :await_up_timeout, await_timeout)
           }}

        {:error, reason} ->
          unless lane?, do: connect_failed(metadata, reason)
          {:stop, reason}
      end
    end

    @impl GenServer
    def handle_call(:await_up, _from, %{status: :up} = state) do
      {:reply, :ok, state}
    end

    def handle_call(:await_up, from, %{status: :connecting} = state) do
      {:noreply, %{state | waiters: [from | state.waiters]}}
    end

    def handle_call({:give_up, tag}, _from, state),
      do: {:reply, :ok, %{state | lanes: HTTP1Lanes.give_up(state.lanes, tag)}}

    def handle_call({:attach_lane, token, lane}, _from, state) do
      case HTTP1Lanes.attach_lane(state.lanes, token, lane) do
        {:ok, lanes} ->
          {:reply, :ok, %{state | lanes: lanes}}

        {:error, lanes} ->
          {:reply, {:error, "the HTTP/1.1 connection slot expired"}, %{state | lanes: lanes}}
      end
    end

    def handle_call(:disconnect, _from, %{gun_pid: gun_pid} = state) do
      if gun_pid, do: :ok = :gun.shutdown(gun_pid)
      reply_waiters(state, {:error, :disconnected})
      {:stop, :normal, :ok, %{state | waiters: []}}
    end

    def handle_call(request, _from, %{http1?: true, lane?: false} = state)
        when elem(request, 0) in [:request, :open_stream] and
               map_size(state.response_processes) > 0 do
      {:reply, {:busy, state.spec}, state}
    end

    def handle_call({:request, method, path, headers, body, deadline}, {caller_pid, _}, state) do
      start_stream(state, caller_pid, deadline, fn gun_pid, opts ->
        do_request(gun_pid, method, path, headers, body, opts)
      end)
    end

    def handle_call({:open_stream, path, headers, deadline}, {caller_pid, _}, state) do
      start_stream(state, caller_pid, deadline, fn gun_pid, opts ->
        :gun.post(gun_pid, path, headers, opts)
      end)
    end

    def handle_call({:send_data, stream_ref, fin, data}, _from, %{gun_pid: gun_pid} = state) do
      # A stream that was cancelled or has ended takes no more data.
      if gun_pid && response_pid(state, stream_ref) do
        :ok = :gun.data(gun_pid, stream_ref, fin, data)
      end

      {:reply, :ok, state}
    end

    def handle_call({:cancel, stream_ref}, _from, state) do
      {:reply, :ok, cancel_stream(state, stream_ref, nil, true)} |> lane_done()
    end

    @impl GenServer
    def handle_cast({:reserve_lane, caller, tag}, state),
      do: {:noreply, %{state | lanes: HTTP1Lanes.reserve(state.lanes, caller, tag)}}

    def handle_cast({:release_lane, token}, state),
      do: {:noreply, %{state | lanes: HTTP1Lanes.free(state.lanes, token)}}

    @impl GenServer
    def handle_info(message, state), do: message |> do_info(state) |> lane_done()

    defp do_info({:lane_expired, ref}, state),
      do: {:noreply, %{state | lanes: HTTP1Lanes.free(state.lanes, ref)}}

    defp do_info({:DOWN, ref, :process, _pid, _reason}, state)
         when is_map_key(state.lanes.monitors, ref),
         do: {:noreply, %{state | lanes: HTTP1Lanes.free(state.lanes, ref)}}

    # Messages from a connection that was retired are not about this one.
    defp do_info(message, %{gun_pid: current} = state)
         when elem(message, 0) in [:gun_up, :gun_down, :gun_error, :gun_notify] and
                elem(message, 1) != current do
      {:noreply, state}
    end

    defp do_info(
           {:gun_up, gun_pid, protocol},
           %{status: :connecting, gun_pid: gun_pid} = state
         ) do
      Process.cancel_timer(state.await_timer)
      state = %{state | await_timer: nil}

      case protocol do
        proto
        when proto == :http2 or
               (proto == :http and state.channel.protocol in [:connect, :grpc_web]) ->
          unless state.lane? do
            Telemetry.execute(
              :connected,
              %{generation: 1},
              state |> metadata() |> Map.put(:reconnect, false)
            )
          end

          reply_waiters(state, :ok)

          {:noreply, %{state | status: :up, generation: 1, waiters: [], http1?: proto == :http}}

        proto ->
          :gun.shutdown(gun_pid)
          reason = "Error when opening connection: protocol #{proto} is not http2"

          Telemetry.execute(
            :connect_error,
            %{},
            Map.merge(metadata(state), %{stage: :http2, reason: reason})
          )

          Telemetry.execute(
            :stopped,
            %{streams_terminated: 0},
            Map.put(metadata(state), :reason, reason)
          )

          fail_connect(state, reason)
      end
    end

    defp do_info(:await_up_timeout, %{status: :connecting, gun_pid: gun_pid} = state) do
      :gun.shutdown(gun_pid)
      connect_failed(metadata(state), :timeout)
      fail_connect(%{state | await_timer: nil}, :timeout)
    end

    defp do_info(:await_up_timeout, state), do: {:noreply, state}

    defp do_info({:gun_up, _gun_pid, proto}, state)
         when proto == :http2 or
                (proto == :http and state.channel.protocol in [:connect, :grpc_web]) do
      generation = state.generation + 1

      Telemetry.execute(
        :connected,
        %{generation: generation},
        state |> metadata() |> Map.put(:reconnect, true)
      )

      {:noreply,
       %{state | generation: generation, max_concurrent_streams: :unknown, http1?: proto == :http}}
    end

    defp do_info({:gun_up, _gun_pid, _protocol}, state), do: {:noreply, state}

    defp do_info({:stream_expired, stream_ref, response_pid}, state) do
      cond do
        response_pid(state, stream_ref) != response_pid ->
          {:noreply, state}

        # HTTP/1.1 cannot reset one request, so the connection is closed. The next call
        # opens it again.
        state.http1? ->
          {:noreply, state |> drop_response_pid(stream_ref) |> retire_http1()}

        true ->
          # Give deadline response frames already in flight a chance to close the
          # stream before Gun sends RST_STREAM. Gun 2.4 treats late HEADERS after
          # a local reset as a connection error.
          Process.send_after(
            self(),
            {:cancel_expired_stream, stream_ref},
            @deadline_cancel_grace_ms
          )

          {:noreply, drop_response_pid(state, stream_ref)}
      end
    end

    defp do_info({:cancel_expired_stream, stream_ref}, %{gun_pid: gun_pid} = state) do
      cancel_stream(gun_pid, stream_ref)
      {:noreply, state}
    end

    defp do_info({:gun_down, _gun_pid, _protocol, reason, killed_streams}, state) do
      {new_state, killed_count} =
        Enum.reduce(killed_streams, {state, 0}, fn stream_ref, {acc, count} ->
          if response_pid = response_pid(acc, stream_ref) do
            send(response_pid, {:connection_down, reason})
            {drop_response_pid(acc, stream_ref), count + 1}
          else
            {acc, count}
          end
        end)

      metadata = Map.put(metadata(state), :reason, reason)

      unless state.lane?,
        do: Telemetry.execute(:down, %{streams_terminated: killed_count}, metadata)

      {:noreply, %{new_state | max_concurrent_streams: :unknown}}
    end

    defp do_info({:gun_notify, _gun_pid, :settings_changed, settings}, state) do
      max = normalize_max_streams(Map.get(settings, :max_concurrent_streams, :unknown))

      if max != state.max_concurrent_streams do
        Telemetry.execute(:settings, %{}, Map.put(metadata(state), :max_concurrent_streams, max))
      end

      {:noreply, %{state | max_concurrent_streams: max}}
    end

    defp do_info(
           {:DOWN, _monitor_ref, :process, gun_pid, reason},
           %{status: :connecting, gun_pid: gun_pid} = state
         ) do
      Process.cancel_timer(state.await_timer)
      connect_failed(metadata(state), {:down, reason})
      fail_connect(%{state | await_timer: nil}, {:down, reason})
    end

    # Gun is gone for good (reconnect retries exhausted or a crash). Fail all
    # in-flight streams and stop
    defp do_info({:DOWN, _monitor_ref, :process, gun_pid, reason}, %{gun_pid: gun_pid} = state) do
      Enum.each(state.response_processes, fn {_stream_ref, entry} ->
        pid =
          case entry do
            %{response_pid: p} -> p
            {p, _} -> p
            _ -> nil
          end

        if is_pid(pid) do
          send(pid, {:connection_down, reason})
        end
      end)

      {:stop, {:shutdown, {:gun_down, reason}}, state}
    end

    defp do_info({:DOWN, monitor_ref, :process, _pid, _reason}, %{gun_pid: gun_pid} = state) do
      case find_stream_by_monitor(state, monitor_ref) do
        {stream_ref, entry} ->
          cancelled? = cancel_stream(gun_pid, stream_ref)

          response_pid =
            case entry do
              %{response_pid: pid} -> pid
              {pid, _} -> pid
              _ -> nil
            end

          caller_monitor =
            case entry do
              %{caller_monitor: mon} -> mon
              _ -> nil
            end

          if monitor_ref == caller_monitor and is_pid(response_pid) and
               Process.alive?(response_pid) do
            GenServer.stop(response_pid, :normal)
          end

          state = drop_response_pid(state, stream_ref)
          {:noreply, if(cancelled?, do: retire_http1(state), else: state)}

        nil ->
          {:noreply, state}
      end
    end

    defp do_info({:gun_error, _conn_pid, stream_ref, reason}, state) do
      Logger.debug(
        "#{inspect(__MODULE__)} received gun_error for stream #{inspect(stream_ref)}: #{inspect(reason)}"
      )

      {:noreply, drop_response_pid(state, stream_ref)}
    end

    defp do_info(msg, state) do
      Logger.warning("#{inspect(__MODULE__)} received unexpected message: #{inspect(msg)}")
      {:noreply, state}
    end

    # A stream that has already finished is gone from Gun, which answers a cancel
    # with a gun_error about the missing stream. Only reset the ones still open.
    # Returns whether it reset a stream that was open.
    defp cancel_stream(nil, _stream_ref), do: false

    defp cancel_stream(gun_pid, stream_ref) do
      case :gun.stream_info(gun_pid, stream_ref) do
        {:ok, :undefined} ->
          false

        {:ok, _info} ->
          :gun.cancel(gun_pid, stream_ref)
          true

        {:error, :not_connected} ->
          false
      end
    end

    # HTTP/1.1 cannot abandon one request: Gun keeps the connection and waits for the
    # response to the request that was cancelled, and the calls after it wait behind
    # that. The connection is closed instead, and the next call opens it again.
    defp retire_http1(%{http1?: true, lane?: false, gun_pid: gun_pid} = state)
         when is_pid(gun_pid) and map_size(state.response_processes) == 0 do
      :gun.close(gun_pid)
      %{state | gun_pid: nil}
    end

    defp retire_http1(state), do: state

    # A lane ends with its one call.
    defp lane_done({:noreply, %{lane?: true, served?: true} = state} = reply),
      do: if(map_size(state.response_processes) == 0, do: {:stop, :normal, state}, else: reply)

    defp lane_done({:reply, response, %{lane?: true, served?: true} = state} = reply),
      do:
        if(map_size(state.response_processes) == 0,
          do: {:stop, :normal, response, state},
          else: reply
        )

    defp lane_done(reply), do: reply

    defp ensure_gun(%{gun_pid: nil} = state) do
      case open(state.channel.host, state.channel.port, state.gun_open_opts) do
        {:ok, gun_pid} ->
          case :gun.await_up(gun_pid, state.await_timeout) do
            {:ok, protocol} ->
              Process.monitor(gun_pid)
              generation = state.generation + 1

              Telemetry.execute(
                :connected,
                %{generation: generation},
                state |> metadata() |> Map.put(:reconnect, true)
              )

              {:ok,
               %{state | gun_pid: gun_pid, generation: generation, http1?: protocol == :http}}

            {:error, reason} ->
              :gun.close(gun_pid)
              {:error, reason, state}
          end

        {:error, reason} ->
          {:error, reason, state}
      end
    end

    defp ensure_gun(state), do: {:ok, state}

    defp start_stream(state, caller_pid, deadline, open_fun) do
      case ensure_gun(state) do
        {:ok, %{gun_pid: gun_pid} = state} ->
          with {:ok, response_pid} <- start_response_process(),
               stream_ref <- open_fun.(gun_pid, req_opts(state, response_pid)),
               state <- put_response_pid(state, stream_ref, response_pid, caller_pid),
               :ok <- StreamResponseProcess.track(response_pid, self(), stream_ref, deadline) do
            {:reply, {:ok, %{stream_ref: stream_ref, response_pid: response_pid}}, state}
          else
            {:error, reason} -> {:reply, {:error, reason}, state}
          end

        {:error, reason, state} ->
          {:reply, {:error, reason}, state}
      end
    end

    @impl GenServer
    # A failed connect already published `:stopped` with the connect error as reason
    def terminate(_reason, %{status: :failed}), do: :ok

    def terminate(_reason, %{lane?: true, response_processes: processes} = state) do
      Enum.each(processes, fn {stream_ref, _entry} ->
        send(response_pid(state, stream_ref), {:connection_down, :closed})
      end)

      if state.gun_pid, do: :gun.close(state.gun_pid)
      :ok
    end

    def terminate(reason, %{response_processes: processes} = state) do
      # Response processes are linked, so a crash takes them down, but a normal
      # exit leaves them waiting for messages that will never come.
      Enum.each(processes, fn {stream_ref, _entry} ->
        send(response_pid(state, stream_ref), {:connection_down, :closed})
      end)

      Telemetry.execute(
        :stopped,
        %{streams_terminated: map_size(processes)},
        Map.put(metadata(state), :reason, reason)
      )

      :ok
    end

    defp do_request(gun_pid, "GET", path, headers, nil, opts),
      do: :gun.get(gun_pid, path, headers, opts)

    defp do_request(gun_pid, "POST", path, headers, body, opts),
      do: :gun.post(gun_pid, path, headers, body, opts)

    defp open({:local, socket_path}, _port, open_opts), do: :gun.open_unix(socket_path, open_opts)
    defp open(host, port, open_opts), do: :gun.open(parse_address(host), port, open_opts)

    defp parse_address(host) do
      host = String.to_charlist(host)

      case :inet.parse_address(host) do
        {:ok, address} -> address
        {:error, _} -> host
      end
    end

    defp via(channel) do
      {:via, Registry, {GRPC.Client.Registry, {__MODULE__, owner_key(channel)}}}
    end

    # Gun sends each DATA frame to `reply_to`, and stops reopening the stream's window
    # once `flow` frames are unread. `StreamResponseProcess` returns the frames it hands out.
    defp req_opts(%{flow: :infinity}, response_pid), do: %{reply_to: response_pid}
    defp req_opts(%{flow: flow}, response_pid), do: %{reply_to: response_pid, flow: flow}

    defp window_to_flow(:infinity), do: :infinity

    defp window_to_flow(bytes) when is_integer(bytes),
      do: max(div(bytes + @frame_size - 1, @frame_size), 1)

    defp start_response_process do
      StreamResponseProcess.start_link()
    end

    defp put_response_pid(
           %{response_processes: processes} = state,
           stream_ref,
           response_pid,
           caller_pid
         ) do
      response_monitor = Process.monitor(response_pid)
      caller_monitor = if is_pid(caller_pid), do: Process.monitor(caller_pid), else: nil

      entry = %{
        response_pid: response_pid,
        response_monitor: response_monitor,
        caller_pid: caller_pid,
        caller_monitor: caller_monitor
      }

      new_state = %{
        state
        | response_processes: Map.put(processes, stream_ref, entry),
          served?: true
      }

      emit_streams(new_state, map_size(new_state.response_processes))
      new_state
    end

    defp drop_response_pid(%{response_processes: processes} = state, stream_ref) do
      case Map.pop(processes, stream_ref) do
        {%{response_monitor: r_mon, caller_monitor: c_mon}, remaining} ->
          if r_mon, do: Process.demonitor(r_mon, [:flush])
          if c_mon, do: Process.demonitor(c_mon, [:flush])
          new_state = %{state | response_processes: remaining}
          emit_streams(new_state, map_size(remaining))
          new_state

        {{_response_pid, monitor_ref}, remaining} ->
          Process.demonitor(monitor_ref, [:flush])
          new_state = %{state | response_processes: remaining}
          emit_streams(new_state, map_size(remaining))
          new_state

        {nil, _remaining} ->
          state
      end
    end

    defp find_stream_by_monitor(%{response_processes: processes}, monitor_ref) do
      Enum.find(processes, fn {_stream_ref, entry} ->
        case entry do
          %{response_monitor: r_mon, caller_monitor: c_mon} ->
            r_mon == monitor_ref or c_mon == monitor_ref

          {_pid, r_mon} ->
            r_mon == monitor_ref

          _ ->
            false
        end
      end)
    end

    defp response_pid(%{response_processes: processes}, stream_ref) do
      case Map.get(processes, stream_ref) do
        %{response_pid: response_pid} -> response_pid
        {response_pid, _monitor_ref} -> response_pid
        nil -> nil
      end
    end

    defp cancel_stream(state, stream_ref, expected_pid, stop?) do
      response_pid = response_pid(state, stream_ref)

      if response_pid && (is_nil(expected_pid) or response_pid == expected_pid) do
        :ok = :gun.cancel(state.gun_pid, stream_ref)
        if stop?, do: stop_response_process(response_pid)
        state |> drop_response_pid(stream_ref) |> retire_http1()
      else
        state
      end
    end

    defp stop_response_process(response_pid) do
      GRPC.Client.Adapters.Gun.StreamResponseProcess.cancel(response_pid)
    end

    defp emit_streams(%{lane?: true}, _active_streams), do: :ok

    defp emit_streams(state, active_streams) do
      Telemetry.execute(:streams, %{active: active_streams}, metadata(state))
    end

    defp normalize_max_streams(:infinity), do: :infinity
    defp normalize_max_streams(value) when is_integer(value) and value > 0, do: value
    defp normalize_max_streams(_value), do: :unknown

    # Stops with `:normal` so `GRPC.Client.Supervisor` doesn't log every failed
    # connect; the reason reaches callers through the waiter replies.
    defp fail_connect(state, reason) do
      reply_waiters(state, {:error, reason})
      {:stop, :normal, %{state | status: :failed, waiters: []}}
    end

    defp reply_waiters(%{waiters: waiters}, reply) do
      Enum.each(waiters, &GenServer.reply(&1, reply))
    end

    defp connect_failed(metadata, reason) do
      maybe_connect_error(metadata, reason)
      Telemetry.execute(:stopped, %{streams_terminated: 0}, Map.put(metadata, :reason, reason))
    end

    defp maybe_connect_error(metadata, reason) do
      if stage = connect_stage(reason) do
        Telemetry.execute(
          :connect_error,
          %{},
          Map.merge(metadata, %{stage: stage, reason: reason})
        )
      end
    end

    defp connect_stage(reason) when reason in [:nxdomain, :host_not_found], do: :resolve

    defp connect_stage(reason) when reason in [:econnrefused, :enetunreach, :ehostunreach],
      do: :tcp

    defp connect_stage({:tls_alert, _detail}), do: :tls
    defp connect_stage({:down, reason}), do: connect_stage(reason)
    defp connect_stage({_tag, reason}), do: connect_stage(reason)
    defp connect_stage(_reason), do: nil

    defp metadata(%{channel: channel, logical_connection_ref: logical_ref}),
      do: metadata(channel, logical_ref)

    defp metadata(channel, logical_ref) do
      %{
        logical_connection_ref: logical_ref,
        transport_ref: self(),
        target: {channel.host, channel.port},
        adapter: GRPC.Client.Adapters.Gun
      }
    end

    defp owner_key(%{ref: ref, host: host, port: port}), do: {ref, host, port}
  end
end
