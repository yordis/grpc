# Connect conformance

This directory runs the [connectrpc/conformance](https://github.com/connectrpc/conformance)
suite against the Elixir gRPC library, as a server (`bin/server`) and as a client (`bin/client`).

The goal is that every case passes with empty known-failing lists. The lists in `config/`
exist only for failures that are being worked on, and each group has its root cause written
above it. There are no flaky allowances: a case either passes or is a known failure.

## Setup

```sh
conformance/bin/fetch-runner      # downloads the pinned runner (v1.0.7), verifies its checksum
```

The runner lands in `conformance/.runner/` (gitignored). The harness builds against the
sibling `grpc`, `grpc_server` and `grpc_core` directories, so local library changes are used
as is. After changing library code, recompile the path dependencies:

```sh
cd conformance && mix deps.compile grpc_core grpc_server grpc --force
```

## Run everything

```sh
conformance/run.sh config/grpc.yaml                              # server: gRPC and gRPC-Web
conformance/run.sh config/full.yaml                              # server: adds Connect (measures the gap)
CLIENT_ADAPTER=mint conformance/run.sh config/client.yaml        # client, Mint adapter
CLIENT_ADAPTER=gun  conformance/run.sh config/client.yaml        # client, Gun adapter
CLIENT_ADAPTER=mint conformance/run.sh config/client.connect.yaml # client, Connect protocol, Mint adapter
CLIENT_ADAPTER=mint conformance/run.sh config/client.grpcweb.yaml # client, gRPC-Web protocol, Mint adapter
```

`run.sh` applies `config/<name>.known_failing.txt` (server) or
`config/client.<adapter>.known_failing.txt` (client) when the file exists. The run exits 0
only when every case outside the list passes and every case in the list still fails.

To see the real state, run without a list:

```sh
KNOWN_FAILING= conformance/run.sh config/grpc.yaml
```

## Run one suite or case

Extra arguments go to the runner. `--run` takes a case name or a glob, where `**` matches
any number of path segments:

```sh
conformance/run.sh config/grpc.yaml --run 'Basic/**'
conformance/run.sh config/grpc.yaml --run 'Errors/**/unary/aborted' --trace
CLIENT_ADAPTER=gun conformance/run.sh config/client.yaml --run 'Timeouts/**' -v
```

`--trace` prints the full HTTP exchange of failing cases. A failing case prints its name,
which is also the pattern to put in a known-failing list.

## Shrink the known-failing lists

When a library fix lands, run the config with its list. A case that now passes is reported as
`was expected to fail but did not`. Delete the matching line (or the whole group when its
cause is fixed) and run again. When the list is empty, delete the file.

Patterns match whole path segments, for example
`Errors/**/Protocol:PROTOCOL_GRPC/**/Codec:CODEC_PROTO/**/unary/aborted`. A `*` only works
as a full segment, so partial wildcards such as `Protocol:*` do not match.

## What is covered

| Config | Mode | Scope |
| --- | --- | --- |
| `config/grpc.yaml` | server | gRPC and gRPC-Web, proto and JSON, identity and gzip, every stream type, HTTP/1.1, HTTP/2, h2c, TLS, TLS client certificates, trailers, message receive limit |
| `config/full.yaml` | server | the same plus Connect, which the library does not implement |
| `config/client.connect.yaml` | client | the Connect protocol (`protocol: :connect`) with the Mint adapter over HTTP/1.1 and HTTP/2, h2c, TLS and client certificates, proto and JSON, identity and gzip, every stream type, GET, timeouts, cancellation, message receive limit |
| `config/client.grpcweb.yaml` | client | the gRPC-Web protocol (`protocol: :grpc_web`) with the Mint adapter over HTTP/1.1 and HTTP/2, h2c, TLS and client certificates, proto and JSON, identity and gzip, every stream type, trailers, timeouts, cancellation, message receive limit |
| `config/client.yaml` | client | gRPC over HTTP/2 with the Mint or Gun adapter, proto and JSON, identity and gzip, every stream type, TLS and client certificates, message receive limit |

Left off on purpose: Connect GET and Connect in `grpc.yaml` (no Connect support), HTTP/1.1
and gRPC-Web in `client.yaml` (the client speaks gRPC over HTTP/2 only), and half-duplex
bidirectional streaming over HTTP/1.1 for the client.

## Current results

Measured with empty known-failing lists on the integration branch (`KNOWN_FAILING=`):

| Run | Passed | Failed | Total |
| --- | ---: | ---: | ---: |
| Server, `config/full.yaml` (gRPC, gRPC-Web and Connect) | 3820 | 0 | 3820 |
| Client, `config/client.yaml`, Mint | 1052 | 0 | 1052 |
| Client, `config/client.yaml`, Gun | 1052 | 0 | 1052 |

Every known-failing list is empty, so the lists are only comments. When a regression or a new
feature adds failures, add them back as grouped globs with the root cause written above each
group, and remove them as the fixes land.

## Layout

- `bin/server`, `bin/client`: launchers started by the runner.
- `lib/conformance/main.ex`, `service.ex`: server handshake and the conformance service.
- `lib/conformance/client/`: client program. `call.ex` performs one call through the public
  `GRPC.Stub` API, `gate.ex` serializes calls that change the process-wide receive limit, and
  `main.ex` runs calls concurrently with a 25 second deadline each, so a call the library
  never finishes fails only its own case.
- `lib/conformance/pinned_cert.ex`: trusts exactly the self-signed certificates the runner
  provides.
