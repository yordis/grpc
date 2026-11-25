defmodule GRPC.Integration.ScriptedH2Server do
  @moduledoc """
  A bare HTTP/2 server that answers every request stream with a fixed script of
  frames, so a test can put on the wire what no real gRPC server sends: repeated
  header entries, a response without `grpc-status`, a bare HTTP status, a stream
  that ends without trailers.

  With `notify: pid`, every request HEADERS frame is reported to `pid` as
  `{:request_headers, [{name, value}]}`.

  A script is a list of steps, run once the client ends its request stream:

    * `{:headers, [{name, value}]}` - a HEADERS frame, entries sent as given
    * `{:headers, [{name, value}], :fin}` - the same, ending the stream
    * `{:data, binary}` / `{:data, binary, :fin}` - a DATA frame
    * `{:rst, error_code}` - a RST_STREAM frame
    * `{:sleep, ms}` - waits before the next step
    * `:close` - closes the TCP connection
  """

  import Bitwise

  @preface "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"

  @doc "Starts the server and returns its port. It stops with the calling test."
  def start(script, opts \\ []) do
    notify = Keyword.get(opts, :notify)
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)
    pid = spawn_link(fn -> accept_loop(listen, script, notify) end)

    ExUnit.Callbacks.on_exit(fn ->
      Process.unlink(pid)
      Process.exit(pid, :kill)
      :gen_tcp.close(listen)
    end)

    port
  end

  defp accept_loop(listen, script, notify) do
    case :gen_tcp.accept(listen) do
      {:ok, socket} ->
        pid = spawn(fn -> serve(socket, script, notify) end)
        :gen_tcp.controlling_process(socket, pid)
        accept_loop(listen, script, notify)

      {:error, _} ->
        :ok
    end
  end

  defp serve(socket, script, notify) do
    {:ok, @preface} = :gen_tcp.recv(socket, byte_size(@preface))
    :ok = :gen_tcp.send(socket, frame(4, 0, 0, <<>>))
    state = %{encoder: :cow_hpack.init(), decoder: :cow_hpack.init(), notify: notify}
    loop(socket, script, state)
  end

  defp loop(socket, script, state) do
    with {:ok, <<len::24, type, flags, _::1, stream::31>>} <- :gen_tcp.recv(socket, 9),
         {:ok, payload} <- recv_payload(socket, len) do
      state = report_headers(state, type, payload)
      handle(socket, script, state, type, flags, stream)
    else
      _ -> :gen_tcp.close(socket)
    end
  end

  defp report_headers(%{decoder: decoder} = state, 1, block) do
    {headers, decoder} = :cow_hpack.decode(block, decoder)
    if state.notify, do: send(state.notify, {:request_headers, headers})
    %{state | decoder: decoder}
  end

  defp report_headers(state, _type, _payload), do: state

  defp recv_payload(_socket, 0), do: {:ok, <<>>}
  defp recv_payload(socket, len), do: :gen_tcp.recv(socket, len)

  # SETTINGS without ACK
  defp handle(socket, script, state, 4, flags, _stream) when (flags &&& 1) == 0 do
    :ok = :gen_tcp.send(socket, frame(4, 1, 0, <<>>))
    loop(socket, script, state)
  end

  # HEADERS or DATA ending the request
  defp handle(socket, script, state, type, flags, stream)
       when type in [0, 1] and (flags &&& 1) == 1 do
    case run(socket, script, state, stream) do
      {:ok, state} -> loop(socket, script, state)
      :closed -> :gen_tcp.close(socket)
    end
  end

  defp handle(socket, script, state, _type, _flags, _stream), do: loop(socket, script, state)

  defp run(_socket, [], state, _stream), do: {:ok, state}

  defp run(socket, [:close | _], _state, _stream) do
    :gen_tcp.close(socket)
    :closed
  end

  defp run(socket, [{:sleep, ms} | rest], state, stream) do
    Process.sleep(ms)
    run(socket, rest, state, stream)
  end

  defp run(socket, [{:rst, code} | rest], state, stream) do
    :ok = :gen_tcp.send(socket, frame(3, 0, stream, <<code::32>>))
    run(socket, rest, state, stream)
  end

  defp run(socket, [{:headers, headers} | rest], state, stream),
    do: send_headers(socket, rest, state, stream, headers, 0x4)

  defp run(socket, [{:headers, headers, :fin} | rest], state, stream),
    do: send_headers(socket, rest, state, stream, headers, 0x5)

  defp run(socket, [{:data, data} | rest], state, stream) do
    :ok = :gen_tcp.send(socket, frame(0, 0, stream, data))
    run(socket, rest, state, stream)
  end

  defp run(socket, [{:data, data, :fin} | rest], state, stream) do
    :ok = :gen_tcp.send(socket, frame(0, 1, stream, data))
    run(socket, rest, state, stream)
  end

  defp send_headers(socket, rest, state, stream, headers, flags) do
    {block, encoder} = :cow_hpack.encode(headers, state.encoder)
    :ok = :gen_tcp.send(socket, frame(1, flags, stream, block))
    run(socket, rest, %{state | encoder: encoder}, stream)
  end

  defp frame(type, flags, stream, payload) do
    payload = IO.iodata_to_binary(payload)
    <<byte_size(payload)::24, type, flags, 0::1, stream::31, payload::binary>>
  end
end
