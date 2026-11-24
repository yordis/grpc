defmodule Connectrpc.Conformance.V1.HTTPVersion do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "connectrpc.conformance.v1.HTTPVersion",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :HTTP_VERSION_UNSPECIFIED, 0
  field :HTTP_VERSION_1, 1
  field :HTTP_VERSION_2, 2
  field :HTTP_VERSION_3, 3
end

defmodule Connectrpc.Conformance.V1.Protocol do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "connectrpc.conformance.v1.Protocol",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :PROTOCOL_UNSPECIFIED, 0
  field :PROTOCOL_CONNECT, 1
  field :PROTOCOL_GRPC, 2
  field :PROTOCOL_GRPC_WEB, 3
end

defmodule Connectrpc.Conformance.V1.Codec do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "connectrpc.conformance.v1.Codec",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :CODEC_UNSPECIFIED, 0
  field :CODEC_PROTO, 1
  field :CODEC_JSON, 2
  field :CODEC_TEXT, 3
end

defmodule Connectrpc.Conformance.V1.Compression do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "connectrpc.conformance.v1.Compression",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :COMPRESSION_UNSPECIFIED, 0
  field :COMPRESSION_IDENTITY, 1
  field :COMPRESSION_GZIP, 2
  field :COMPRESSION_BR, 3
  field :COMPRESSION_ZSTD, 4
  field :COMPRESSION_DEFLATE, 5
  field :COMPRESSION_SNAPPY, 6
end

defmodule Connectrpc.Conformance.V1.StreamType do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "connectrpc.conformance.v1.StreamType",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :STREAM_TYPE_UNSPECIFIED, 0
  field :STREAM_TYPE_UNARY, 1
  field :STREAM_TYPE_CLIENT_STREAM, 2
  field :STREAM_TYPE_SERVER_STREAM, 3
  field :STREAM_TYPE_HALF_DUPLEX_BIDI_STREAM, 4
  field :STREAM_TYPE_FULL_DUPLEX_BIDI_STREAM, 5
end

defmodule Connectrpc.Conformance.V1.Code do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "connectrpc.conformance.v1.Code",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :CODE_UNSPECIFIED, 0
  field :CODE_CANCELED, 1
  field :CODE_UNKNOWN, 2
  field :CODE_INVALID_ARGUMENT, 3
  field :CODE_DEADLINE_EXCEEDED, 4
  field :CODE_NOT_FOUND, 5
  field :CODE_ALREADY_EXISTS, 6
  field :CODE_PERMISSION_DENIED, 7
  field :CODE_RESOURCE_EXHAUSTED, 8
  field :CODE_FAILED_PRECONDITION, 9
  field :CODE_ABORTED, 10
  field :CODE_OUT_OF_RANGE, 11
  field :CODE_UNIMPLEMENTED, 12
  field :CODE_INTERNAL, 13
  field :CODE_UNAVAILABLE, 14
  field :CODE_DATA_LOSS, 15
  field :CODE_UNAUTHENTICATED, 16
end

defmodule Connectrpc.Conformance.V1.Config do
  @moduledoc false

  use Protobuf,
    full_name: "connectrpc.conformance.v1.Config",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :features, 1, type: Connectrpc.Conformance.V1.Features

  field :include_cases, 2,
    repeated: true,
    type: Connectrpc.Conformance.V1.ConfigCase,
    json_name: "includeCases"

  field :exclude_cases, 3,
    repeated: true,
    type: Connectrpc.Conformance.V1.ConfigCase,
    json_name: "excludeCases"
end

defmodule Connectrpc.Conformance.V1.Features do
  @moduledoc false

  use Protobuf,
    full_name: "connectrpc.conformance.v1.Features",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :versions, 1, repeated: true, type: Connectrpc.Conformance.V1.HTTPVersion, enum: true
  field :protocols, 2, repeated: true, type: Connectrpc.Conformance.V1.Protocol, enum: true
  field :codecs, 3, repeated: true, type: Connectrpc.Conformance.V1.Codec, enum: true
  field :compressions, 4, repeated: true, type: Connectrpc.Conformance.V1.Compression, enum: true

  field :stream_types, 5,
    repeated: true,
    type: Connectrpc.Conformance.V1.StreamType,
    json_name: "streamTypes",
    enum: true

  field :supports_h2c, 6, proto3_optional: true, type: :bool, json_name: "supportsH2c"
  field :supports_tls, 7, proto3_optional: true, type: :bool, json_name: "supportsTls"

  field :supports_tls_client_certs, 8,
    proto3_optional: true,
    type: :bool,
    json_name: "supportsTlsClientCerts"

  field :supports_trailers, 9, proto3_optional: true, type: :bool, json_name: "supportsTrailers"

  field :supports_half_duplex_bidi_over_http1, 10,
    proto3_optional: true,
    type: :bool,
    json_name: "supportsHalfDuplexBidiOverHttp1"

  field :supports_connect_get, 11,
    proto3_optional: true,
    type: :bool,
    json_name: "supportsConnectGet"

  field :supports_message_receive_limit, 12,
    proto3_optional: true,
    type: :bool,
    json_name: "supportsMessageReceiveLimit"
end

defmodule Connectrpc.Conformance.V1.ConfigCase do
  @moduledoc false

  use Protobuf,
    full_name: "connectrpc.conformance.v1.ConfigCase",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :version, 1, type: Connectrpc.Conformance.V1.HTTPVersion, enum: true
  field :protocol, 2, type: Connectrpc.Conformance.V1.Protocol, enum: true
  field :codec, 3, type: Connectrpc.Conformance.V1.Codec, enum: true
  field :compression, 4, type: Connectrpc.Conformance.V1.Compression, enum: true

  field :stream_type, 5,
    type: Connectrpc.Conformance.V1.StreamType,
    json_name: "streamType",
    enum: true

  field :use_tls, 6, proto3_optional: true, type: :bool, json_name: "useTls"

  field :use_tls_client_certs, 7,
    proto3_optional: true,
    type: :bool,
    json_name: "useTlsClientCerts"

  field :use_message_receive_limit, 8,
    proto3_optional: true,
    type: :bool,
    json_name: "useMessageReceiveLimit"
end

defmodule Connectrpc.Conformance.V1.TLSCreds do
  @moduledoc false

  use Protobuf,
    full_name: "connectrpc.conformance.v1.TLSCreds",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :cert, 1, type: :bytes
  field :key, 2, type: :bytes
end
