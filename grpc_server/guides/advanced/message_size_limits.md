# Message size limits

A server limits the size of the messages it sends and receives. A message over a
limit fails the call with status `RESOURCE_EXHAUSTED` (`8`), and the error message
says which limit it hit.

| Option | Where to set it | Default | Applies to |
|--------|-----------------|---------|------------|
| `:max_message_length` | `config :grpc, max_message_length: bytes` | 2 GiB (`2_147_483_648`) | One message the server receives |
| `:max_send_message_length` | `config :grpc, max_send_message_length: bytes` | 2 GiB (`2_147_483_648`) | One message the server sends |
| `:max_body_size` | `GRPC.Server.Supervisor` option | 4 MiB (`4_194_304`) | The request body of a call that sends one request (unary and server streaming). On a request stream it applies only when set explicitly. `:infinity` removes it |
| `:max_decompressed_message_length` | `config :grpc, max_decompressed_message_length: bytes` | 4 MiB | One message after gzip decompression |

## `:max_message_length`

```elixir
# config/config.exs
config :grpc, max_message_length: 16 * 1024 * 1024
```

The limit is read on every message, so it also works from `Application.put_env/3`
at run time. It applies to what the server receives: a request message over the
limit is refused, from the length in its prefix, before your handler runs. The
client gets `RESOURCE_EXHAUSTED` with a message such as
`Received message is too large (2048 bytes, the limit is 1000 bytes)`. The server
checks the prefix of a gRPC message in the first chunk that holds it, for a unary
request and for each message of a request stream, and stops reading there. It
sends the error and ends the stream, so the client sends about one flow-control
window of the message and no more. The check covers gRPC bodies, not gRPC-web text
or transcoded JSON.

## `:max_send_message_length`

```elixir
config :grpc, max_send_message_length: 16 * 1024 * 1024
```

The limit of one message the server sends. It is independent of
`:max_message_length`: lowering what the server receives does not lower what it
sends, and a reply is not refused because a request of that size would be. A reply
over the limit is not sent, and the client gets `RESOURCE_EXHAUSTED` with a message
such as `Encoded message is too large (2048 bytes), the limit is 1000 bytes`.

The setting is global to the node. A node that runs a client and a server applies
the same limit to both. Compressed messages count by their size on the wire.

## `:max_body_size`

`:max_body_size` caps the whole request body. Set it on the supervisor:

```elixir
children = [
  {GRPC.Server.Supervisor, endpoint: MyApp.Endpoint, port: 50051, max_body_size: 64 * 1024 * 1024}
]
```

The 4 MiB default applies when the option is absent or `nil`, including with
`GRPC.Server.start_endpoint/3`, to a call whose request is one body: unary and
server-streaming calls over gRPC, gRPC-Web, Connect and transcoding. A request stream
(client-streaming and bidirectional calls) is bounded per message by `:max_message_length`,
so a long-lived stream of small messages is not cut off. Set `:max_body_size` explicitly
to also cap the total of a request stream. A request over the limit fails with `RESOURCE_EXHAUSTED` and `Request body too large`.
It has to be at least as large as the biggest request you accept, so raise it
together with `:max_message_length` for large requests.

## Sending very large replies

On a loopback connection, a unary reply of 100 MB, 300 MB and 600 MB is sent
without error by the Cowboy adapter, using its default settings. No setting is needed
to send a reply larger than the HTTP/2 flow-control windows, which start at 64 KiB.

If a large reply fails, look at these first:

* **The client's timeout.** A unary call gives up after 10 seconds unless the client
  passes `:timeout`. The server learns the deadline from the `grpc-timeout` header
  and stops the call with `DEADLINE_EXCEEDED` when it passes. Raise the client's
  `:timeout`.
* **Cowboy timeouts.** The adapter sets `idle_timeout` and `inactivity_timeout` to
  `:infinity` unless you pass `:idle_timeout` in `:adapter_opts`. A finite value
  closes a connection that sends no data for that long.
* **Window and frame sizes.** `:initial_stream_window_size`,
  `:initial_connection_window_size` and `:max_frame_size_sent` in `:adapter_opts`
  are passed to Cowboy. See the `cowboy_http2` documentation for their meaning.
