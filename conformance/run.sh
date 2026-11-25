#!/bin/sh
# Usage: conformance/run.sh [path-to-connectconformance] <config.yaml> [extra runner args...]
#
# Without a runner path, uses conformance/.runner/connectconformance (see bin/fetch-runner).
# A config named client*.yaml runs the runner in client mode against bin/client, any other
# config runs server mode against bin/server.
#
# Environment:
#   CLIENT_ADAPTER  mint (default) or gun; selects the client adapter in client mode.
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
(cd "$here" && mix deps.get && mix compile) >&2 </dev/null

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

extra=""
[ -n "${KNOWN_FAILING:-}" ] && extra="--known-failing @$KNOWN_FAILING"
# shellcheck disable=SC2086
exec "$runner" --conf "$config" --mode "$mode" $extra "$@" -- $program
