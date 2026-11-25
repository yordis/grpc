# Connect conformance

This directory runs the [connectrpc/conformance](https://github.com/connectrpc/conformance)
suite against the Elixir gRPC library, as a server (`bin/server`) and as a client (`bin/client`).

Every case passes. The known-failing lists in `config/` are empty (comments only) and there
is no flaky mechanism: a case either passes or is a known failure, and an intermittent failure
is a bug.

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

Server mode, covering gRPC, gRPC-Web and Connect (3820 cases):

```sh
conformance/run.sh config/full.yaml
```

Client mode, gRPC over HTTP/2, with the Mint and the Gun adapter (1052 cases each):

```sh
CLIENT_ADAPTER=mint conformance/run.sh config/client.yaml
CLIENT_ADAPTER=gun  conformance/run.sh config/client.yaml
```

Client mode, Connect protocol with the Mint and the Gun adapter (1764 cases each):

```sh
CLIENT_ADAPTER=mint conformance/run.sh config/client.connect.yaml
CLIENT_ADAPTER=gun  conformance/run.sh config/client.connect.yaml
```

Client mode, gRPC-Web protocol with the Mint and the Gun adapter (2046 cases each):

```sh
CLIENT_ADAPTER=mint conformance/run.sh config/client.grpcweb.yaml
CLIENT_ADAPTER=gun  conformance/run.sh config/client.grpcweb.yaml
```

Narrower server configs run a slice of `full.yaml`: `config/grpc.yaml` for gRPC and gRPC-Web
only, `config/connect.yaml` for Connect only.

`run.sh` applies `config/<name>.known_failing.txt` (server) or
`config/client.<adapter>.known_failing.txt` (client) when the file exists. The run exits 0
only when every case outside the list passes and every case in the list still fails.

To see the real state, run without a list:

```sh
KNOWN_FAILING= conformance/run.sh config/full.yaml
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
| `config/full.yaml` | server | gRPC, gRPC-Web and Connect, proto and JSON, identity and gzip, every stream type, HTTP/1.1, HTTP/2, h2c, TLS, TLS client certificates, trailers, message receive limit |
| `config/grpc.yaml` | server | the gRPC and gRPC-Web part of `full.yaml` |
| `config/connect.yaml` | server | the Connect part of `full.yaml` |
| `config/client.yaml` | client | gRPC over HTTP/2 with the Mint or Gun adapter, proto and JSON, identity and gzip, every stream type, TLS and client certificates, message receive limit |
| `config/client.connect.yaml` | client | the Connect protocol (`protocol: :connect`) with the Mint or Gun adapter over HTTP/1.1 and HTTP/2, h2c, TLS and client certificates, proto and JSON, identity and gzip, every stream type, GET, timeouts, cancellation, message receive limit |
| `config/client.grpcweb.yaml` | client | the gRPC-Web protocol (`protocol: :grpc_web`) with the Mint or Gun adapter over HTTP/1.1 and HTTP/2, h2c, TLS and client certificates, proto and JSON, identity and gzip, every stream type, trailers, timeouts, cancellation, message receive limit |

Left off on purpose: HTTP/1.1 and gRPC-Web in `client.yaml` (the client speaks gRPC over HTTP/2 only), and half-duplex
bidirectional streaming over HTTP/1.1 for the client.

## Current results

Measured with the committed, empty known-failing lists:

| Run | Passed | Failed | Total |
| --- | ---: | ---: | ---: |
| Server, `config/full.yaml` (gRPC, gRPC-Web and Connect) | 3820 | 0 | 3820 |
| Client, `config/client.yaml`, Mint | 1052 | 0 | 1052 |
| Client, `config/client.yaml`, Gun | 1052 | 0 | 1052 |
| Client, `config/client.connect.yaml`, Mint | 1764 | 0 | 1764 |
| Client, `config/client.grpcweb.yaml`, Mint | 2046 | 0 | 2046 |

When a regression or a new feature adds failures, add them to the matching list as grouped
globs with the root cause written above each group, and remove them as the fixes land.

## Layout

- `bin/server`, `bin/client`: launchers started by the runner.
- `lib/conformance/main.ex`, `service.ex`: server handshake and the conformance service.
- `lib/conformance/client/`: client program. `call.ex` performs one call through the public
  `GRPC.Stub` API, `gate.ex` serializes calls that change the process-wide receive limit, and
  `main.ex` runs calls concurrently with a 25 second deadline each, so a call the library
  never finishes fails only its own case.
- `lib/conformance/pinned_cert.ex`: trusts exactly the self-signed certificates the runner
  provides.
