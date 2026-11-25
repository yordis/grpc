# Changelog

## Unreleased

### Enhancements

  * The server speaks the Connect protocol (https://connectrpc.com/docs/protocol). A call that arrives with a Connect content type reaches the same handler as a gRPC call, and `stream.access_mode` is `:connectrpc`. Unary, client, server and bidirectional streaming calls work, over HTTP/1.1 and HTTP/2, with proto and JSON, identity and gzip. A unary method marked `idempotency_level = NO_SIDE_EFFECTS` is also served as GET. Connect errors, `connect-timeout-ms` and `connect-protocol-version` are handled, and a request with an unsupported verb or content type gets a Connect error. The `GRPC.Server.Test` helpers accept the new access mode. The Connect protocol is covered by the Connect conformance suite, which also covers gRPC and gRPC-Web (see `conformance/README.md`).

  * The server keeps an HTTP/1.1 connection alive when the router answers a call itself, for example for an unknown method, and when a reply precedes the end of a chunked request body. An idle HTTP/1.1 connection lasts as long as an idle HTTP/2 one.

  * New `GRPC.Server.Stream.timeout_ms/1` returns the timeout the client sent, in milliseconds, or `nil`. It reads `grpc-timeout` for gRPC and gRPC-Web and `connect-timeout-ms` for Connect, so a handler or interceptor needs no header parsing. `GRPC.Server.Stream` has a new `:timeout_ms` field.

### Behavior Changes

  * The Connect protocol is opt-in: a server serves it only when it sets `use GRPC.Server, service: ..., connect: true`. With the option off, which is the default, a request keeps the protocol it had before Connect: a `POST` with `application/json` to a gRPC path is a transcoded call, with `grpc-status` trailers and the gRPC to HTTP status map, not a Connect call with a JSON error body. `application/proto`, `application/connect+*` and `GET ?encoding=...` are served only with the option on. Upgrade: set `connect: true` on each `use GRPC.Server` that should answer Connect clients (the Connect conformance server does so).

  * Breaking: the limit of what the server sends is independent of the receive limit. `config :grpc, max_message_length: bytes` limits only the messages the server receives again. The limit of what the server sends is `config :grpc, max_send_message_length: bytes`, which is independent and defaults to 2 GiB. Before, the send limit followed the receive limit unless it was set, so a server with a low receive limit refused a reply of the same size. Upgrade: if you relied on `:max_message_length` to cap replies, set `:max_send_message_length` too.

  * With `connect: true`, a `POST` whose content type is neither gRPC nor Connect gets HTTP 415. Before, the server handled it as gRPC with proto. When the request has no `Content-Type`, the server falls back to `Accept`, so a `POST` without a content type and with `Accept: */*`, the `curl` default, gets 415, and one with `Accept: application/json` is read as Connect with JSON. A server without `connect: true` is not changed. Upgrade: send a `Content-Type` of gRPC, gRPC-Web or Connect.

  * An error keeps the trailers a handler set with `GRPC.Server.set_trailers/2`, and custom headers go in a HEADERS frame ahead of the error trailers. An error is no longer Trailers-Only once a handler or interceptor set any header. The CORS interceptor always sets headers, so a gRPC-Web server with CORS answers an error with a header block and then trailers. Upgrade: a client that expected a Trailers-Only error from such a server must read the status from the trailers.

  * The trailer block of a gRPC-Web response ends every line with CRLF, as the protocol says. The bytes on the wire change.

  * The server sets the HTTP/2 flow control window margins to 0, so the window it announces follows what a stream asked for.

  * The server drains an HTTP/1.1 request body of up to 1 MB, for up to 1 second, when it ends a call or the router answers 400 or 404 before the handler reads it, so the connection can serve the next request.

### Bug Fixes

  * A Connect request whose content type does not fit the method is refused with HTTP 415, and `Accept-Post` names the content types the method takes. A unary content type (`application/proto`, `application/json`) on a streaming method used to give a server stream only its last message, and a client stream read the unary body as envelopes. The streaming content types (`application/connect+*`) on a unary method are refused too. Upgrade: a Connect client must use the unary content types for unary methods and the streaming ones for the rest, as the Connect spec says.

  * A call's deadline timer is cancelled when its reply is complete, and a deadline that still arrives after the reply is ignored. Before, a Connect unary call whose deadline fired between the reply and the end of the RPC process made the request process crash with `response_already_sent`, and a Ranch error report. No upgrade action is needed.

  * An HTTP/1.1 connection that sends no request is closed again, after 60 seconds. The adapter had set Cowboy's `request_timeout` to `:idle_timeout`, which defaults to `:infinity`, so idle sockets lived forever and could fill `:max_connections`. The `:request_timeout` adapter option (default `60000`) is independent of `:idle_timeout`. The default is above Cowboy's 5 seconds on purpose, so a client that reuses a kept-alive connection does not hit a close. Upgrade: set `adapter_opts: [request_timeout: ...]` to change it, or `:infinity` to restore the previous behavior.

  * Breaking: the 4 MiB default of `:max_body_size` now applies. `GRPC.Server.start_endpoint/3` passed `nil` as the default, and the Cowboy handler compared a number to `nil`, which is never over, so a server started without the option had no limit. The handler now treats an absent or `nil` option as 4 MiB, and `:infinity` removes the limit. Upgrade: a server that relied on the missing limit to accept a request over 4 MiB must set `:max_body_size`, to a larger number of bytes or to `:infinity`.

  * The default `:max_body_size` (4 MiB) no longer cuts off a long-lived client-streaming or bidirectional call once its messages add up to 4 MiB. The default applies only to a call whose request is one body (unary and server streaming, over gRPC, gRPC-Web, Connect and transcoding). A request stream is bounded per message by `:max_message_length`. An explicit `:max_body_size` still caps the total of a request stream. Upgrade: if you set `:max_body_size` only to cap a stream's total, it still does; if you relied on the unreleased default to cap streams, set `:max_body_size` explicitly.

  * A gRPC-Web response echoes the request's `grpc-web` content type.

  * A gRPC call with a JSON codec is answered as `application/grpc+json`.

  * A gRPC call that fails before it starts is answered with a gRPC content type.

  * Content types of Connect no longer log an invalid content-type warning.

  * A connection no longer starves its window when streams end with data the server did not ask for.

  * A server stream no longer hangs when two calls on one connection fill Cowboy's send buffers. If a stream waited for its stream buffer to drain and the connection buffer then filled, the second alarm made the stream forget it was waiting. When the buffers drained it got no ack, and the call never ended, however fast the client read (#652).

  * `GRPC.Server.Supervisor` crashed on unix sockets (`adapter_opts: [ip: {:local, path}]`). This is now fixed (#665).

## v1.1.0 - 2026-11-13

### Enhancements

  * New Cowboy adapter options `:max_connection_age` and `:max_connection_age_grace`, in milliseconds. After the age, the server sends GOAWAY, lets open calls finish, and closes the connection. After the grace, it ends calls that are still open. The age has ±10% jitter and counts from the first call on the connection. Both default to `:infinity`, which changes nothing. Clients that balance over many servers, for example behind a Kubernetes headless service, then reconnect and find new replicas. The new "Connection age" guide has the details and the parts of gRPC proposal A9 that are not done: server keepalive PINGs and the check of client PINGs. Cowboy must change for both (#355).

  * New Cowboy adapter option `:max_connection_idle`, in milliseconds. When a connection has no open call for this time, the server closes it in the same way as for `:max_connection_age`: GOAWAY, then the open calls finish. The time counts from the end of the last call and has no jitter. A call that arrives while the server closes the connection is not lost. Unlike A9, the time starts at the first call. A9 starts it at the creation of the connection. Cowboy has no hook before the first stream. A connection that sends no call is never closed by this option. Only Cowboy's `:idle_timeout`, which this adapter sets to `:infinity` by default, limits it. The default is `:infinity`, which changes nothing. You can set `:max_connection_age` and `:max_connection_idle` together. The first limit to end closes the connection (#355).

  * New event: `[:grpc, :server, :rpc, :send_error]`. The Cowboy adapter publishes it when the handler returns but the adapter cannot encode, compress or send the reply. The metadata has `:kind`, `:reason`, `:stacktrace` and `:path`. It is not an `:exception` event, because the telemetry span of the handler is closed at that time. A client that disconnects during the reply still causes only `:abort`, because nothing raises. A new section in the error handling guide shows how to send these events to Sentry or Bugsnag (#349).

  * `GRPC.Server.Test` runs server interceptors in a test with no endpoint, server process or socket. `build_stream/3` makes a `GRPC.Server.Stream` for an RPC, `run_interceptors/4` runs the chain with the same code the server uses, and `response_headers/1`, `response_trailers/1` and `replies/1` return what was sent. See the new "Testing interceptors" guide (#423).

  * `config :grpc, max_message_length: bytes` now limits one message the server receives, as well as one it sends, and `guides/advanced/message_size_limits.md` documents it with `:max_body_size` and the other limits (#387). The default stays 2 GiB. A request message over the limit is refused with `RESOURCE_EXHAUSTED` before the handler runs, and the error says the limit. The Cowboy handler checks the 5-byte length prefix in the first chunk that holds it, for a unary request and for each message of a request stream, and stops reading, so a client sends about one flow-control window of an oversize message. This needs no `grpc_core` change.

  * `[:grpc, :server, :rpc, :abort]` is now published when the adapter stops an in-flight RPC — an expired deadline, a client cancellation, a dropped connection. The exit signal that stops the RPC process does not unwind it, so `:stop` and `:exception` cannot be published for such a call; the new event carries the stream, server, endpoint, request path, RPC pid and exit reason.

  * A test and a doc note now cover that the Cowboy adapter's accepted sockets, plain and TLS, have `TCP_NODELAY` on. This is Ranch's default and the adapter passes nothing that turns it off (#323).

### Behavior Changes

  * A reply that is over the message size limit now fails with `RESOURCE_EXHAUSTED` instead of `INTERNAL`, and the error message states the limit (#387).

  * A `GRPC.RPCError` raised while the Cowboy adapter sends the reply or the trailers, after the handler returned, or when no handler matches the request, now keeps its status. Before, the client got `UNKNOWN`. For example, a known path called with an HTTP method that the RPC does not accept now gets `UNIMPLEMENTED` (#496).

  * A unary request body that is cut short, or a request stream message with the compressed flag and no `grpc-encoding`, now gets `INTERNAL` instead of `INVALID_ARGUMENT`. A unary call with no message gets `UNIMPLEMENTED`. These are the codes grpc/grpc's `doc/statuscodes.md` gives a library; it never generates `INVALID_ARGUMENT` (#651).

  * The Cowboy adapter now treats a route from an HttpRule as transcoded whatever the `Content-Type` says, with the JSON codec. Before, the header chose the path, and a request to a transcoded URL with `application/grpc` or `application/grpc-web` skipped the path bindings, so its body could set a field the URL fixes, such as `name` in `/v1/messages/{name}`. A CORS preflight is not changed. A call to a transcoded URL with a gRPC body now gets an error from the JSON decoder. A request-streaming call in transcoding mode now gets `UNIMPLEMENTED`, because transcoding maps one request message and a stream has no path binding to apply (GHSA-xc5v-89vq-hv5m).

### Bug Fixes

  * A call refused for `:max_body_size` no longer stalls the other calls on its connection. The client can still have DATA in flight for a refused call, and Cowboy dropped it without giving the window back. After enough refusals the connection window was empty, no data could arrive, and every later call waited until its deadline. Each stream with a body now asks Cowboy for one frame of flow when it opens, which makes Cowboy top up an empty window. Tests cover refusals one at a time, eight at a time, and a call that opens first and sends its body after the window would have emptied (GHSA-7x9q-vvph-rjcr).
  * A client-streaming or bidirectional call whose request body ends inside a message, such as a lone 5-byte length prefix that declares 100 bytes, no longer spins one scheduler at 100% CPU for as long as the connection stays open. The stream reader asked the handler for more body, got an empty answer because the body was already read, and asked again with no limit and no timeout. It now ends the call with `INTERNAL`. Every release up to v1.0.6 is affected; the fix landed in #651. Tests cover the report's input and a bidirectional call (GHSA-c2h9-f9cc-27xh).
  * `GRPC.Server.send_reply/3` now waits until the Cowboy adapter has taken the reply, so a client that reads slowly slows the server stream. Before, replies piled up in the stream process's mailbox without limit. This also covers `GRPC.Stream.run_with/3`. The wait is bounded by Cowboy's `max_stream_buffer_size` and `max_connection_buffer_size`, by the call's deadline, and by the new `:send_timeout` adapter option (default `:infinity`). If the stream's process is gone, `send_reply/3` exits with `:shutdown`. See the "Slow clients and server streams" guide (#496).
  * `GRPC.Server.send_reply/3` no longer leaves a late ack in the caller's mailbox after a `:send_timeout` or deadline wait ends. It raises `:deadline_exceeded` at once, and queues nothing, when the call's deadline has already passed. A unary reply whose send times out, after the handler returned, now gives the client `DEADLINE_EXCEEDED`. Before, it gave `UNKNOWN`. The guide lists three limits: a handler blocked in `send_reply/3` does not read requests, a reply whose wait timed out is still sent later, and a call whose deadline has passed raises before it queues the reply (#496).
  * A compressor that raises does not crash the Cowboy handler process now. The client gets `INTERNAL` with a `grpc-status`. Before, it got no `grpc-status`. The adapter logs the error one time, with `crash_reason`.
  * A listen failure now logs which endpoint could not start and why, for example `Could not start MyApp.Endpoint: port 50051 is already in use (eaddrinuse)`. Before, the Cowboy adapter's `:eaddrinuse` clause never matched Ranch's `{:listen_error, ref, :eaddrinuse}`, and nothing named the port. Under a supervisor, the child's error is now `{:listen_failed, message, reason}`, with the old term as `reason`; match on `:eaddrinuse` anywhere in it. `GRPC.Server.start_endpoint/3` still returns the same `{:error, reason}`. `GRPC.Server.Adapters.Cowboy.start_link/5` replaces `start_link/4` and takes the port. With Ranch 2, the adapter now also logs `Running ... with Cowboy using ...` at startup (#330).
  * Request data that waits for its handler is credited to the client once, when the handler reads it. It was credited on arrival and again on read, so the receive window grew without bound and a client was never held back. A handler that stops reading now holds its client to the stream window (`initial_stream_window_size`).
  * Unless set, the Cowboy adapter's connection window is 16 stream windows (`initial_connection_window_size`, `connection_window_margin_size`), so streams whose handlers stop reading can't take the whole connection window from the other streams on it.
  * Servers started with `GRPC.Server.start/3` (no endpoint) now each keep their own routes. The last server started used to replace the routes of the others, and a call could fail with UNIMPLEMENTED or 404. Servers started with an endpoint are not changed (#649).
  * A request message that does not decode now gets an error code `INTERNAL`, with a `grpc-message` that says what failed, as opposed to crashing the process.

## v1.0.6 (2026-11-06)

### Security

  * Enforce `max_body_size` on request-streaming and bidirectional-streaming RPCs. Before this, a client could send an unbounded body across many small frames and exhaust server memory. See [GHSA-vx6q-cr5q-945g](https://github.com/elixir-grpc/grpc/security/advisories/GHSA-vx6q-cr5q-945g) (CVE-2026-71397).

## v1.0.4 (2026-0-15)

### Bug Fixes

  * Remove dangling typespecs

## v1.0.0 (2026-06-15)

### Enhancements

  * The client and server implementations were separated into two distinct packages to improve modularity and maintainability.
  * A t() typespec was added to GRPC.Server.Adapters.ReportException to improve type documentation and tooling support.
  * IPv6 support was added to the gRPC gun adapter, enabling connections over IPv6 networks.
  * Virtual channels can now be explicitly named, allowing clearer identification and management of channels.
  * Support was added for grpc-web trailers encoded in the message body, improving compatibility with grpc-web clients.
  * The inbound gRPC deadline is now surfaced on `GRPC.Server.Stream` via the `deadline` field (absolute monotonic time in ms, or `nil` if no deadline was set) and the `GRPC.Server.Stream.remaining_ms/1` helper function, enabling deadline budget propagation in interceptors and handlers.
  * `application/json` content-type matching in transcoding is now loosened to support additional content types with parameters.
  * Boolean query parameters are now correctly coerced to Elixir boolean types in transcoding.
  * Elixir 1.20 is now supported with updated dependency constraints.

### Bug Fixes

  * Fixed an issue in stream map_error where send_response handling could behave incorrectly.
  * Resolved a persistent_term memory leak in GRPC.Client.Connection that occurred when a connection was disconnected.
  * Corrected the cacertfile option name.
  * Added detection of name collisions and introduced a fallback mechanism for the call function.
  * Fixed broken benchmark links in the project.
  * Resolved two compiler warnings/errors in grpc.
  * Ensured $callers are properly propagated in GRPC.Stream Flow workers.
  * Fixed address key generation in handle_info(:refresh) to correctly support Unix domain sockets.
  * Fixed an issue where buffers were not fully drained when a single HTTP/2 frame carried multiple gRPC messages.
  * Resolved a client disconnection handling issue.
  * Fixed type system warnings related to Elixir 1.19.
  * Fixed an error handling issue in stream map_error.
  * Corrected the connection state initialization created by build_direct_state.
  * Added a configurable request body size limit to prevent potential resource exhaustion.
  * Fixed path parameters to correctly take precedence over query parameters in HTTP transcoding.
  * Fixed unsafe `binary_to_term` decoding in the erlpack codec to block dangerous terms.
  * Fixed a zip bomb vulnerability in the gzip compressor.

### Documentation Fixes

  * Corrected documentation related to unary responses and added clarification about the adapter_opts.cred option.

## v0.11.5 (2025-11-14)

### Enhancements

  * Feat add `exception_log_filter` option to server

### Bug fixes

  * Fix ensure thers is only one `GRPC.Client.Supervisor`.
  * Fix report `GRPC.Errors` as normal shutdowns

## v0.11.4 (2025-11-07)

### Enhancements

  * Feat added new function to handle side-effects.
  * Feat added error handler for unary and stream pipelines.
  * Docs adds a better explanation of the different types of input.
  * Docs improvements to module documentation.
  * Docs livebooks added directly to the documentation.

### Bug fixes

  * Fix refresh error spam on direct_state (no lb).
  * Fix correct return type in doc.
