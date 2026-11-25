defmodule Conformance.OSProcess do
  @moduledoc false

  # Stops the OS process `os_pid` only while it is still the one that was started, which
  # `identity` (taken when it started) tells. Once it has exited, its pid may belong to
  # another process, and that one must not be killed.
  def stop(os_pid, identity) do
    if identity != "" and identity(os_pid) == identity do
      System.cmd("kill", [Integer.to_string(os_pid)], stderr_to_stdout: true)
    end

    :ok
  end

  # When the process started. Its command line is no use here: a launcher script replaces it
  # with the program it runs, while the start time stays.
  def identity(os_pid) do
    {out, _} = System.cmd("ps", ["-o", "lstart=", "-p", Integer.to_string(os_pid)], stderr_to_stdout: true)
    String.trim(out)
  end

  def alive?(os_pid) do
    match?({_, 0}, System.cmd("kill", ["-0", Integer.to_string(os_pid)], stderr_to_stdout: true))
  end
end
