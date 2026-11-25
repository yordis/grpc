Code.require_file("support/os_process.ex", __DIR__)

# The launchers load the build of CONFORMANCE_ENV, `dev` by default, which `mix test` does not
# compile. Point them at the build this run just compiled, so a fresh checkout passes and a
# stale dev build is never what a test exercises.
System.put_env("CONFORMANCE_ENV", to_string(Mix.env()))

ExUnit.start()
