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

    server = start("server")
    Port.command(server, @request)
    assert <<size::32-big, _::binary-size(size)>> = handshake(server)
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
        cd: @root
      ])

    stop_on_exit(port)
    port
  end

  defp start(program) do
    port = Port.open({:spawn_executable, Path.join(@bin, program)}, [:binary, :exit_status])
    stop_on_exit(port)
    port
  end

  # A server does not stop when its stdin closes, so the test stops the OS process.
  defp stop_on_exit(port) do
    {:os_pid, os_pid} = Port.info(port, :os_pid)
    on_exit(fn -> System.cmd("kill", [Integer.to_string(os_pid)], stderr_to_stdout: true) end)
  end

  # The wait only bounds a hang. A launcher that waits on the lock never answers, so the
  # test fails when the wait ends, and a passing launcher is not timed.
  defp handshake(port, acc \\ <<>>) do
    receive do
      {^port, {:data, data}} ->
        acc = acc <> data

        case acc do
          <<size::32-big, rest::binary>> when byte_size(rest) >= size -> acc
          _ -> handshake(port, acc)
        end

      {^port, {:exit_status, status}} ->
        flunk("server exited with #{status} before the handshake: #{inspect(acc)}")
    after
      30_000 -> flunk("no handshake: the launcher is waiting for the build lock")
    end
  end
end
