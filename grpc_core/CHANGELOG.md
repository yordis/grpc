# Changelog

## Unreleased

### Enhancements

  * `GRPC.RPCError` has new `:headers` and `:trailers` fields, which a client sets from the reply when the server sent them with the error. New `GRPC.Transport.HTTP2.status_from_http/1` maps an HTTP status without `grpc-status` to a gRPC status, and `GRPC.Transport.HTTP2.grpc_content_type?/1` checks a response content type.

### Behavior Changes

  * `GRPC.Transport.HTTP2.extract_metadata/1` and `decode_headers/1` keep every value of a header that appears more than once, joined with a comma, where the last value won before.

### Bug Fixes

  * `GRPC.Codec.JSON.decode/2` decodes into the message struct.
  * `grpc-status-details-bin` is encoded as unpadded base64.

## v1.1.0 - 2026-11-13

### Behavior Changes

  * `GRPC.Message.from_data/2` answers a buffer that does not hold a whole message, such as a body cut short, with `INTERNAL` instead of `INVALID_ARGUMENT` as per [the standard](https://github.com/grpc/grpc/blob/master/doc/statuscodes.md).

### Bug Fixes

  * `GRPC.Codec.Erlpack.decode/2` refuses compressed terms. The VM inflated them in full before any check ran, so a small request could exhaust server memory.
  * `GRPC.Message.from_data/2` no longer crashes on invalid trailers.
  * `GRPC.Message.from_data/2` now returns error code `INTERNAL` instead of crashing on data which fails to decompress.
