#!/bin/sh
# Usage: conformance/run.sh [path-to-connectconformance] <config.yaml> [extra runner args...]
# Without a runner path, uses conformance/.runner/connectconformance (see bin/fetch-runner).
# The grpc.yaml config uses the files under config/ by default. Optionally set KNOWN_FAILING and KNOWN_FLAKY to files listing test cases that
# are expected to fail, or allowed to fail, respectively.
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
extra=""
if [ "$(basename "$config")" = "grpc.yaml" ]; then
  : "${KNOWN_FAILING=$here/config/grpc.known_failing.txt}"
  : "${KNOWN_FLAKY=$here/config/grpc.known_flaky.txt}"
fi
if [ -n "$KNOWN_FAILING" ]; then
  extra="--known-failing @$KNOWN_FAILING"
fi
if [ -n "$KNOWN_FLAKY" ]; then
  extra="$extra --known-flaky @$KNOWN_FLAKY"
fi
# shellcheck disable=SC2086
exec "$runner" --conf "$config" --mode server $extra "$@" -- "$here/bin/server"
