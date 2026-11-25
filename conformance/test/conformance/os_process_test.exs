defmodule Conformance.OSProcessTest do
  use ExUnit.Case, async: true

  alias Conformance.OSProcess

  # A pid can be reused once its process has gone, so a test that stops a program after the
  # fact must not kill whatever holds that pid by then.
  test "stops the process it started" do
    {_port, os_pid} = sleeper()
    identity = OSProcess.identity(os_pid)

    OSProcess.stop(os_pid, identity)

    assert wait_until_gone(os_pid)
  end

  test "leaves alone a process that is not the one it started" do
    {_port, os_pid} = sleeper()
    on_exit(fn -> System.cmd("kill", [Integer.to_string(os_pid)]) end)

    OSProcess.stop(os_pid, "not the process that was started")

    assert OSProcess.alive?(os_pid)
  end

  defp sleeper do
    port = Port.open({:spawn_executable, System.find_executable("sleep")}, [:binary, args: ["60"]])
    {:os_pid, os_pid} = Port.info(port, :os_pid)
    {port, os_pid}
  end

  # A stopped process may stay listed until its parent collects it.
  defp wait_until_gone(os_pid) do
    Enum.any?(1..100, fn _ ->
      not OSProcess.alive?(os_pid) or (Process.sleep(50) && false)
    end)
  end
end
