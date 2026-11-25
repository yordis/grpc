defmodule Conformance.OSProcess do
  @moduledoc false

  # Stops the OS process behind a port.
  def stop(os_pid, _identity) do
    System.cmd("kill", [Integer.to_string(os_pid)], stderr_to_stdout: true)
    :ok
  end

  # What a process looks like to `ps`: its start time and its command line.
  def identity(os_pid) do
    {out, _} = System.cmd("ps", ["-o", "lstart=,command=", "-p", Integer.to_string(os_pid)], stderr_to_stdout: true)
    String.trim(out)
  end

  def alive?(os_pid) do
    match?({_, 0}, System.cmd("kill", ["-0", Integer.to_string(os_pid)], stderr_to_stdout: true))
  end
end
