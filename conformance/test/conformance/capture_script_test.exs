defmodule Conformance.CaptureScriptTest do
  use ExUnit.Case, async: true

  @capture Path.expand("../../bin/capture", __DIR__)

  # The runner stops a server it started by killing that process, which under capture is
  # the capture script. The server under it must stop too, or it runs on for good, along
  # with the tee processes that hold its pipes.
  for signal <- ["TERM", "KILL"] do
    @tag :tmp_dir
    test "the program stops when capture is killed with SIG#{signal}", %{tmp_dir: tmp} do
      pidfile = Path.join(tmp, "program.pid")

      port =
        Port.open({:spawn_executable, @capture}, [
          :binary,
          :exit_status,
          args: [Path.join(tmp, "capture"), "/bin/sh", "-c", "echo $$ > #{pidfile}; exec sleep 60"]
        ])

      {:os_pid, capture_pid} = Port.info(port, :os_pid)
      program_pid = wait_for(fn -> File.exists?(pidfile) and String.trim(File.read!(pidfile)) end)
      on_exit(fn -> System.cmd("kill", ["-KILL", program_pid], stderr_to_stdout: true) end)

      assert alive?(program_pid)
      {_, 0} = System.cmd("kill", ["-#{unquote(signal)}", "#{capture_pid}"])

      assert wait_for(fn -> not alive?(program_pid) end),
             "the program #{program_pid} is still running"
    end
  end

  defp alive?(pid) do
    {_, status} = System.cmd("kill", ["-0", pid], stderr_to_stdout: true)
    status == 0
  end

  defp wait_for(fun, tries \\ 50) do
    case fun.() do
      falsy when falsy in [nil, false] and tries > 0 ->
        Process.sleep(100)
        wait_for(fun, tries - 1)

      result ->
        result
    end
  end
end
