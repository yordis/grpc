#!/bin/sh
# Usage: conformance/run.sh <path-to-connectconformance> <config.yaml> [extra runner args...]
# Optionally set KNOWN_FAILING to a file listing known failing test cases.
set -e
runner="$1"
config="$2"
[ -n "$runner" ] && [ -n "$config" ] || { echo "usage: $0 <connectconformance> <config.yaml> [args...]" >&2; exit 2; }
shift 2
here="$(cd "$(dirname "$0")" && pwd)"
(cd "$here" && mix deps.get && mix compile) >&2 </dev/null
extra=""
if [ -n "$KNOWN_FAILING" ]; then
  extra="--known-failing @$KNOWN_FAILING"
fi
# shellcheck disable=SC2086
exec "$runner" --conf "$config" --mode server $extra "$@" -- "$here/bin/server"
