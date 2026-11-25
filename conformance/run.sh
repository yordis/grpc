#!/bin/sh
# Usage: conformance/run.sh [path-to-connectconformance] <config.yaml> [extra runner args...]
#
# Without a runner path, uses conformance/.runner/connectconformance (see bin/fetch-runner).
# A config named client*.yaml runs the runner in client mode against bin/client, any other
# config runs server mode against bin/server.
#
# Environment:
#   CLIENT_ADAPTER  mint (default) or gun; selects the client adapter in client mode.
#   CONFORMANCE_ENV  Mix environment to compile and run, dev by default.
#   CONFORMANCE_CAPTURE_DIR  when set, keeps the bytes each client or server read and wrote, and
#                   its stderr with times, as <dir>/<time>.<pid>.{in,out,err} (see bin/capture).
#                   Gates set it, so a failure always has evidence.
#   KNOWN_FAILING   file of test cases expected to fail. Defaults to config/<name>.known_failing.txt
#                   (config/client.<adapter>.known_failing.txt for the client) when it exists.
#                   Set it to an empty string to run without a list.
set -e
here="$(cd "$(dirname "$0")" && pwd)"
case "${1:-}" in
  *.yaml | "") runner="$here/.runner/connectconformance" ;;
  *) runner="$1"; shift ;;
esac
config="${1:-}"
[ -n "$config" ] || { echo "usage: $0 [connectconformance] <config.yaml> [args...]" >&2; exit 2; }
shift
[ -x "$runner" ] || { echo "runner not found: $runner (run conformance/bin/fetch-runner)" >&2; exit 2; }
# Compile and copy the same build the launchers load.
MIX_ENV="${CONFORMANCE_ENV:-dev}"
export MIX_ENV
(cd "$here" && mix deps.get && mix compile) >&2 </dev/null

# The runner starts a program per test case for as long as the run lasts, and another run's
# compile may rewrite the shared build meanwhile. Give this run its own copy, taken under the
# build lock so it is never half written, and remove it when the run ends. Links left
# dangling by a removed priv directory point nowhere and would fail the copy, so they go first.
shared="$here/_build/${CONFORMANCE_ENV:-dev}/lib"
CONFORMANCE_BUILD="$(mktemp -d "${TMPDIR:-/tmp}/conformance-build.XXXXXX")"
export CONFORMANCE_BUILD
trap 'rm -rf "$CONFORMANCE_BUILD"' EXIT
trap 'exit 130' INT TERM
(cd "$here" && SHARED="$shared" mix run --no-compile --no-deps-check -e \
  'Mix.Project.with_build_lock(fn -> {_, 0} = System.cmd("sh", ["-c", "find -L \"$SHARED\" -type l -exec rm {} + ; cp -RL \"$SHARED/.\" \"$CONFORMANCE_BUILD\""]) end)') >&2 </dev/null

name="$(basename "$config" .yaml)"
case "$name" in
  client*)
    mode=client
    adapter="${CLIENT_ADAPTER:-mint}"
    list="$name.$adapter"
    program="$here/bin/client --adapter $adapter"
    ;;
  *)
    mode=server
    list="$name"
    program="$here/bin/server"
    ;;
esac
[ -f "$here/config/$list.known_failing.txt" ] && : "${KNOWN_FAILING=$here/config/$list.known_failing.txt}"

[ -z "${CONFORMANCE_CAPTURE_DIR:-}" ] || program="$here/bin/capture $CONFORMANCE_CAPTURE_DIR $program"

extra=""
[ -n "${KNOWN_FAILING:-}" ] && extra="--known-failing @$KNOWN_FAILING"
# shellcheck disable=SC2086
"$runner" --conf "$config" --mode "$mode" $extra "$@" -- $program
