defmodule GRPC.Server.Http2WindowTest do
  use GRPC.Integration.TestCase, async: false

  # The connection's receive window is shared by its streams. Cowboy keeps, per connection,
  # the sum of what the streams asked to read, and it tops the window up only to that sum. A
  # stream that is sent more than it asked for (a client may send a whole initial window
  # before the request process reads) and then ends leaves the sum lower than it should be,
  # and later streams on the connection starve.

  defmodule HelloServer do
    use GRPC.Server, service: Helloworld.Greeter.Service

    def say_hello(req, _stream),
      do: %Helloworld.HelloReply{message: "Hello, #{byte_size(req.name)}"}
  end

  @preface "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"
  @path "/helloworld.Greeter/SayHello"

  defp frame(type, flags, stream, payload) do
    <<byte_size(payload)::24, type, flags, 0::1, stream::31, payload::binary>>
  end

  defp lit(name, value), do: <<0, byte_size(name), name::binary, byte_size(value), value::binary>>

  defp headers_frame(stream, flags) do
    block =
      <<0x83, 0x86, 0x04, byte_size(@path), @path::binary, 0x01, 9, "localhost"::binary>> <>
        lit("content-type", "application/grpc+proto") <> lit("te", "trailers")

    frame(1, flags, stream, block)
  end

  defp message(length, size) do
    body = <<0, length::32>>
    body <> :binary.copy("a", size - byte_size(body))
  end

  defp data_frames(stream, body, last_flag) do
    chunks = for <<chunk::binary-size(16_384) <- body>>, do: chunk
    rest = binary_part(body, length(chunks) * 16_384, byte_size(body) - length(chunks) * 16_384)

    frames =
      Enum.map(chunks, &frame(0, 0, stream, &1)) ++
        if(rest == "", do: [], else: [frame(0, last_flag, stream, rest)])

    frames
  end

  # Reads frames until one for `stream` is a HEADERS frame, or the time is out. Window
  # updates are tracked in `state`, and every frame of the server is answered as needed.
  defp new_state(socket), do: %{socket: socket, buffer: <<>>, conn: 65_535, streams: %{}}

  defp recv_frame(state, timeout) do
    case state.buffer do
      <<len::24, type, flags, _::1, stream::31, payload::binary-size(len), rest::binary>> ->
        {:ok, {type, flags, stream, payload}, %{state | buffer: rest}}

      _ ->
        case :gen_tcp.recv(state.socket, 0, timeout) do
          {:ok, data} -> recv_frame(%{state | buffer: state.buffer <> data}, timeout)
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp handle({4, 0, 0, _payload}, state) do
    :ok = :gen_tcp.send(state.socket, frame(4, 1, 0, <<>>))
    state
  end

  defp handle({8, _, 0, <<_::1, inc::31>>}, state), do: %{state | conn: state.conn + inc}

  defp handle({8, _, stream, <<_::1, inc::31>>}, state) do
    %{state | streams: Map.update(state.streams, stream, 65_535 + inc, &(&1 + inc))}
  end

  defp handle({6, 0, 0, payload}, state) do
    :ok = :gen_tcp.send(state.socket, frame(6, 1, 0, payload))
    state
  end

  defp handle(_frame, state), do: state

  defp await_headers(state, stream, timeout) do
    case recv_frame(state, timeout) do
      {:ok, {1, _, ^stream, _}, state} -> {:ok, state}
      {:ok, frame, state} -> await_headers(handle(frame, state), stream, timeout)
      {:error, reason} -> {:error, reason}
    end
  end

  defp await_window(state, needed, timeout, n) do
    if state.conn >= needed do
      {:ok, state}
    else
      case recv_frame(state, timeout) do
        {:ok, frame, state} -> await_window(handle(frame, state), needed, timeout, n)
        {:error, reason} -> {:error, {reason, n, state.conn}}
      end
    end
  end

  # Sends `body` for `stream` as far as the windows allow, reading the server's window
  # updates when they are used up.
  defp send_body(state, stream, body, timeout) do
    window = min(state.conn, Map.get(state.streams, stream, 65_535))

    cond do
      body == "" ->
        {:ok, state}

      window == 0 ->
        case recv_frame(state, timeout) do
          {:ok, frame, state} -> send_body(handle(frame, state), stream, body, timeout)
          {:error, reason} -> {:error, {reason, byte_size(body)}}
        end

      true ->
        size = Enum.min([window, 16_384, byte_size(body)])
        <<chunk::binary-size(size), rest::binary>> = body
        flags = if rest == "", do: 1, else: 0
        :ok = :gen_tcp.send(state.socket, frame(0, flags, stream, chunk))

        state = %{
          state
          | conn: state.conn - size,
            streams: Map.put(state.streams, stream, Map.get(state.streams, stream, 65_535) - size)
        }

        send_body(state, stream, rest, timeout)
    end
  end

  test "streams that end with data they did not ask for do not starve the connection" do
    Application.put_env(:grpc, :max_message_length, 2_000_000)
    on_exit(fn -> Application.delete_env(:grpc, :max_message_length) end)

    run_server(HelloServer, fn port ->
      {:ok, socket} = :gen_tcp.connect(~c"localhost", port, [:binary, active: false])
      :ok = :gen_tcp.send(socket, @preface <> frame(4, 0, 0, <<>>))
      state = new_state(socket)

      # Idle streams hold flow the connection counts.
      idle = Enum.map(0..11, &(&1 * 2 + 1))

      for id <- idle do
        :ok = :gen_tcp.send(socket, headers_frame(id, 4) <> frame(0, 0, id, <<0, 0, 0>>))
      end

      # Streams sent a whole initial window in one go, of a message over the limit. The
      # frames are read before the request process reads any.
      burst = message(5_000_000, 65_535)

      state =
        Enum.reduce(0..59, state, fn n, state ->
          ended = 31 + n * 2
          assert {:ok, state} = await_window(state, 65_535, 2_000, n)

          :ok =
            :gen_tcp.send(
              socket,
              IO.iodata_to_binary([headers_frame(ended, 4) | data_frames(ended, burst, 0)])
            )

          assert {:ok, state} = await_headers(state, ended, 3_000)
          %{state | conn: state.conn - 65_535}
        end)

      # The idle streams end normally, which takes back all the flow they hold.
      state =
        Enum.reduce(idle, state, fn id, state ->
          :ok = :gen_tcp.send(socket, frame(0, 1, id, <<0, 0>>))
          assert {:ok, state} = await_headers(state, id, 5_000)
          state
        end)

      # A later stream sends a message that needs more than what is left of the window.
      later = 301
      :ok = :gen_tcp.send(socket, headers_frame(later, 4))
      payload = message(1_500_000, 1_500_005)
      assert {:ok, state} = send_body(state, later, payload, 3_000)
      assert {:ok, _state} = await_headers(state, later, 3_000)
      :gen_tcp.close(socket)
    end)
  end
end
