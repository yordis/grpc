defmodule Conformance.LauncherTest do
  use ExUnit.Case, async: true

  # The runner gives a client 20 seconds to answer and a server 10. A launcher that goes
  # through Mix waits on the build directory lock for as long as anything else in that build
  # holds it, such as a compile or another run starting up. The runner then sees a program
  # that never starts and fails every case. Launchers must not take that lock.
  @bin Path.expand("../../bin", __DIR__)
  @root Path.expand("../..", __DIR__)

  # An empty size-delimited ServerCompatRequest: plaintext, no limits.
  @request <<0, 0, 0, 0>>

  test "a server starts while another process holds the build lock" do
    hold_build_lock()

    server = start(Path.join(@bin, "server"))
    Port.command(server, @request)
    assert <<size::32-big, _::binary-size(size)>> = handshake(server)
  end

  # The runner reads length-prefixed messages from stdout, so a log line or any other text
  # there is read as a size. Only the protocol may write to it.
  test "text written to stdout while a server starts does not reach the protocol stream" do
    expression = ~s[IO.puts("noise"); Conformance.Main.run()]
    server = start(Path.join(@bin, "launch"), [expression])
    Port.command(server, @request)

    assert <<size::32-big, response::binary-size(size)>> = handshake(server)

    assert %Connectrpc.Conformance.V1.ServerCompatResponse{host: "127.0.0.1"} =
             Connectrpc.Conformance.V1.ServerCompatResponse.decode(response)
  end

  # The device behind stdin starts out decoding UTF-8, and anything that sets its options can
  # put it back, which mangles bytes over 127 or fails the read. The protocol is bytes, so it
  # must not pass through that device. This program never sets the device to bytes.
  test "protocol bytes arrive intact whatever encoding the stdin device is in" do
    expression = """
    unicode = :io.getopts(:standard_io)[:encoding]
    input = Conformance.Protocol.open_input()
    message = Conformance.Protocol.read(input)
    Conformance.Protocol.write((if unicode == :unicode, do: <<1>>, else: <<0>>) <> message)
    System.halt(0)
    """

    # Every byte value, which is not valid UTF-8, then a short second message.
    payload = :binary.list_to_bin(Enum.to_list(0..255))
    program = start(Path.join(@bin, "launch"), [expression])
    Port.command(program, <<byte_size(payload)::32-big, payload::binary>>)

    assert <<size::32-big, response::binary-size(size)>> = handshake(program)
    assert response == <<1>> <> payload
  end

  # Takes the lock the way a compile does and keeps it until the test process ends.
  defp hold_build_lock do
    holder = start_mix("Mix.Project.with_build_lock(fn -> IO.puts(\"locked\"); IO.gets(\"\") end)")

    receive do
      {^holder, {:data, "locked\n"}} -> :ok
      {^holder, {:exit_status, status}} -> flunk("the lock holder exited with #{status}")
    after
      120_000 -> flunk("the lock holder did not start")
    end
  end

  defp start_mix(expression) do
    mix = System.find_executable("mix")

    port =
      Port.open({:spawn_executable, mix}, [
        :binary,
        :exit_status,
        args: ["run", "--no-compile", "--no-deps-check", "-e", expression],
        cd: @root,
        env: [{~c"MIX_ENV", ~c"#{Mix.env()}"}]
      ])

    stop_on_exit(port)
    port
  end

  defp start(program, args \\ []) do
    port = Port.open({:spawn_executable, program}, [:binary, :exit_status, args: args])
    stop_on_exit(port)
    port
  end

  # A server does not stop when its stdin closes, so the test stops the OS process. That runs
  # after the test, when the process may be gone and its pid taken by another program.
  defp stop_on_exit(port) do
    {:os_pid, os_pid} = Port.info(port, :os_pid)
    identity = Conformance.OSProcess.identity(os_pid)
    on_exit(fn -> Conformance.OSProcess.stop(os_pid, identity) end)
  end

  # The wait only bounds a hang. A launcher that waits on the lock never answers, so the
  # test fails when the wait ends, and a passing launcher is not timed.
  defp handshake(port, acc \\ <<>>) do
    receive do
      {^port, {:data, data}} ->
        acc = acc <> data

        case acc do
          <<size::32-big, _::binary>> when size > 65_536 ->
            flunk("stdout does not start with a message: #{inspect(acc)}")

          <<size::32-big, rest::binary>> when byte_size(rest) >= size ->
            acc

          _ -> handshake(port, acc)
        end

      {^port, {:exit_status, status}} ->
        flunk("server exited with #{status} before the handshake: #{inspect(acc)}")
    after
      30_000 -> flunk("no handshake: the launcher is waiting for the build lock")
    end
  end
end
