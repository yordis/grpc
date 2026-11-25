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

  # The runner starts a client or server per test case for as long as the run lasts. Read from
  # the shared build, one of them can load beams that another run's compile is rewriting.
  # run.sh therefore hands the programs a private copy taken under the build lock.
  @tag :tmp_dir
  test "run.sh runs the programs from a private copy of the build", %{tmp_dir: tmp} do
    runner = Path.join(tmp, "runner")
    shared = Path.expand("../../_build/#{Mix.env()}/lib", __DIR__)

    File.write!(runner, """
    #!/bin/sh
    printf '%s' "$CONFORMANCE_BUILD"
    diff -rq "$CONFORMANCE_BUILD" "#{shared}" >&2
    """)

    File.chmod!(runner, 0o755)

    {build, 0} = System.cmd(@run, [runner, "client.yaml"])

    assert build != ""
    refute build == shared
    refute File.exists?(build), "the copy is removed when the run ends"
  end

  test "bin/launch runs from the build it is given" do
    missing = Path.join(System.tmp_dir!(), "no-such-build-#{System.unique_integer([:positive])}")

    assert {output, 2} =
             System.cmd(Path.expand("../../bin/launch", __DIR__), ["System.halt(0)"],
               env: [{"CONFORMANCE_BUILD", missing}],
               stderr_to_stdout: true
             )

    assert output =~ missing
  end
end
