defmodule Conformance.MainTest do
  use ExUnit.Case, async: true

  # The runner starts several server programs at once, each a separate OS process whose
  # unique integers begin at the same value. They all write their TLS files under the
  # system temp directory, so a directory name made of a unique integer alone is shared:
  # one server then loads another's certificate and key, and a client rejects it.
  test "the TLS directory is private to the OS process" do
    assert Conformance.Main.tls_dir() =~ "-#{System.pid()}-"
  end

  test "each call makes a new TLS directory" do
    refute Conformance.Main.tls_dir() == Conformance.Main.tls_dir()
  end
end
