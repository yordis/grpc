defmodule Conformance.RunScriptTest do
  use ExUnit.Case, async: true

  # A failed run that left nothing behind cannot be explained afterwards. With
  # CONFORMANCE_CAPTURE_DIR set, run.sh keeps what every program under test read and wrote.
  @run Path.expand("../../run.sh", __DIR__)

  @tag :tmp_dir
  test "run.sh keeps the bytes a client exchanged with the runner when capture is on", %{tmp_dir: tmp} do
    runner = Path.join(tmp, "runner")
    capture = Path.join(tmp, "capture")

    # Stands in for the conformance runner: runs the program after `--`, feeding it one frame.
    File.write!(runner, """
    #!/bin/sh
    while [ "$1" != "--" ]; do shift; done
    shift
    printf '\\000\\000\\000\\000' | "$@"
    """)

    File.chmod!(runner, 0o755)

    {_, 0} =
      System.cmd(@run, [runner, "client.yaml"],
        env: [{"CONFORMANCE_CAPTURE_DIR", capture}],
        stderr_to_stdout: true
      )

    files = File.ls!(capture)
    assert [input] = Enum.filter(files, &String.ends_with?(&1, ".in"))
    assert File.read!(Path.join(capture, input)) == <<0, 0, 0, 0>>
    assert Enum.any?(files, &String.ends_with?(&1, ".out"))

    [err] = Enum.filter(files, &String.ends_with?(&1, ".err"))
    log = File.read!(Path.join(capture, err))
    assert log =~ ~r/^\d\d:\d\d:\d\d start: /
    assert log =~ ~r/\d\d:\d\d:\d\d end: status \d+/
  end
end
