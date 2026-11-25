defmodule Connectrpc.Conformance.V1.UnaryResponseDefinition do
  @moduledoc false

  use Protobuf,
    full_name: "connectrpc.conformance.v1.UnaryResponseDefinition",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  oneof :response, 0

  field :response_headers, 1,
    repeated: true,
    type: Connectrpc.Conformance.V1.Header,
    json_name: "responseHeaders"

  field :response_data, 2, type: :bytes, json_name: "responseData", oneof: 0
  field :error, 3, type: Connectrpc.Conformance.V1.Error, oneof: 0

  field :response_trailers, 4,
    repeated: true,
    type: Connectrpc.Conformance.V1.Header,
    json_name: "responseTrailers"

  field :response_delay_ms, 6, type: :uint32, json_name: "responseDelayMs"

  field :raw_response, 5,
    type: Connectrpc.Conformance.V1.RawHTTPResponse,
    json_name: "rawResponse"
end

defmodule Connectrpc.Conformance.V1.StreamResponseDefinition do
  @moduledoc false

  use Protobuf,
    full_name: "connectrpc.conformance.v1.StreamResponseDefinition",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :response_headers, 1,
    repeated: true,
    type: Connectrpc.Conformance.V1.Header,
    json_name: "responseHeaders"

  field :response_data, 2, repeated: true, type: :bytes, json_name: "responseData"
  field :response_delay_ms, 3, type: :uint32, json_name: "responseDelayMs"
  field :error, 4, type: Connectrpc.Conformance.V1.Error

  field :response_trailers, 5,
    repeated: true,
    type: Connectrpc.Conformance.V1.Header,
    json_name: "responseTrailers"

  field :raw_response, 6,
    type: Connectrpc.Conformance.V1.RawHTTPResponse,
    json_name: "rawResponse"
end

defmodule Connectrpc.Conformance.V1.UnaryRequest do
  @moduledoc false

  use Protobuf,
    full_name: "connectrpc.conformance.v1.UnaryRequest",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :response_definition, 1,
    type: Connectrpc.Conformance.V1.UnaryResponseDefinition,
    json_name: "responseDefinition"

  field :request_data, 2, type: :bytes, json_name: "requestData"
end

defmodule Connectrpc.Conformance.V1.UnaryResponse do
  @moduledoc false

  use Protobuf,
    full_name: "connectrpc.conformance.v1.UnaryResponse",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :payload, 1, type: Connectrpc.Conformance.V1.ConformancePayload
end

defmodule Connectrpc.Conformance.V1.IdempotentUnaryRequest do
  @moduledoc false

  use Protobuf,
    full_name: "connectrpc.conformance.v1.IdempotentUnaryRequest",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :response_definition, 1,
    type: Connectrpc.Conformance.V1.UnaryResponseDefinition,
    json_name: "responseDefinition"

  field :request_data, 2, type: :bytes, json_name: "requestData"
end

defmodule Connectrpc.Conformance.V1.IdempotentUnaryResponse do
  @moduledoc false

  use Protobuf,
    full_name: "connectrpc.conformance.v1.IdempotentUnaryResponse",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :payload, 1, type: Connectrpc.Conformance.V1.ConformancePayload
end

defmodule Connectrpc.Conformance.V1.ServerStreamRequest do
  @moduledoc false

  use Protobuf,
    full_name: "connectrpc.conformance.v1.ServerStreamRequest",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :response_definition, 1,
    type: Connectrpc.Conformance.V1.StreamResponseDefinition,
    json_name: "responseDefinition"

  field :request_data, 2, type: :bytes, json_name: "requestData"
end

defmodule Connectrpc.Conformance.V1.ServerStreamResponse do
  @moduledoc false

  use Protobuf,
    full_name: "connectrpc.conformance.v1.ServerStreamResponse",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :payload, 1, type: Connectrpc.Conformance.V1.ConformancePayload
end

defmodule Connectrpc.Conformance.V1.ClientStreamRequest do
  @moduledoc false

  use Protobuf,
    full_name: "connectrpc.conformance.v1.ClientStreamRequest",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :response_definition, 1,
    type: Connectrpc.Conformance.V1.UnaryResponseDefinition,
    json_name: "responseDefinition"

  field :request_data, 2, type: :bytes, json_name: "requestData"
end

defmodule Connectrpc.Conformance.V1.ClientStreamResponse do
  @moduledoc false

  use Protobuf,
    full_name: "connectrpc.conformance.v1.ClientStreamResponse",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :payload, 1, type: Connectrpc.Conformance.V1.ConformancePayload
end

defmodule Connectrpc.Conformance.V1.BidiStreamRequest do
  @moduledoc false

  use Protobuf,
    full_name: "connectrpc.conformance.v1.BidiStreamRequest",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :response_definition, 1,
    type: Connectrpc.Conformance.V1.StreamResponseDefinition,
    json_name: "responseDefinition"

  field :full_duplex, 2, type: :bool, json_name: "fullDuplex"
  field :request_data, 3, type: :bytes, json_name: "requestData"
end

defmodule Connectrpc.Conformance.V1.BidiStreamResponse do
  @moduledoc false

  use Protobuf,
    full_name: "connectrpc.conformance.v1.BidiStreamResponse",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :payload, 1, type: Connectrpc.Conformance.V1.ConformancePayload
end

defmodule Connectrpc.Conformance.V1.UnimplementedRequest do
  @moduledoc false

  use Protobuf,
    full_name: "connectrpc.conformance.v1.UnimplementedRequest",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3
end

defmodule Connectrpc.Conformance.V1.UnimplementedResponse do
  @moduledoc false

  use Protobuf,
    full_name: "connectrpc.conformance.v1.UnimplementedResponse",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3
end

defmodule Connectrpc.Conformance.V1.ConformancePayload.RequestInfo do
  @moduledoc false

  use Protobuf,
    full_name: "connectrpc.conformance.v1.ConformancePayload.RequestInfo",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :request_headers, 1,
    repeated: true,
    type: Connectrpc.Conformance.V1.Header,
    json_name: "requestHeaders"

  field :timeout_ms, 2, proto3_optional: true, type: :int64, json_name: "timeoutMs"
  field :requests, 3, repeated: true, type: Google.Protobuf.Any

  field :connect_get_info, 4,
    type: Connectrpc.Conformance.V1.ConformancePayload.ConnectGetInfo,
    json_name: "connectGetInfo"
end

defmodule Connectrpc.Conformance.V1.ConformancePayload.ConnectGetInfo do
  @moduledoc false

  use Protobuf,
    full_name: "connectrpc.conformance.v1.ConformancePayload.ConnectGetInfo",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :query_params, 1,
    repeated: true,
    type: Connectrpc.Conformance.V1.Header,
    json_name: "queryParams"
end

defmodule Connectrpc.Conformance.V1.ConformancePayload do
  @moduledoc false

  use Protobuf,
    full_name: "connectrpc.conformance.v1.ConformancePayload",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :data, 1, type: :bytes

  field :request_info, 2,
    type: Connectrpc.Conformance.V1.ConformancePayload.RequestInfo,
    json_name: "requestInfo"
end

defmodule Connectrpc.Conformance.V1.Error do
  @moduledoc false

  use Protobuf,
    full_name: "connectrpc.conformance.v1.Error",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :code, 1, type: Connectrpc.Conformance.V1.Code, enum: true
  field :message, 2, proto3_optional: true, type: :string
  field :details, 3, repeated: true, type: Google.Protobuf.Any
end

defmodule Connectrpc.Conformance.V1.Header do
  @moduledoc false

  use Protobuf,
    full_name: "connectrpc.conformance.v1.Header",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :name, 1, type: :string
  field :value, 2, repeated: true, type: :string
end

defmodule Connectrpc.Conformance.V1.RawHTTPRequest.EncodedQueryParam do
  @moduledoc false

  use Protobuf,
    full_name: "connectrpc.conformance.v1.RawHTTPRequest.EncodedQueryParam",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :name, 1, type: :string
  field :value, 2, type: Connectrpc.Conformance.V1.MessageContents
  field :base64_encode, 3, type: :bool, json_name: "base64Encode"
end

defmodule Connectrpc.Conformance.V1.RawHTTPRequest do
  @moduledoc false

  use Protobuf,
    full_name: "connectrpc.conformance.v1.RawHTTPRequest",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  oneof :body, 0

  field :verb, 1, type: :string
  field :uri, 2, type: :string
  field :headers, 3, repeated: true, type: Connectrpc.Conformance.V1.Header

  field :raw_query_params, 4,
    repeated: true,
    type: Connectrpc.Conformance.V1.Header,
    json_name: "rawQueryParams"

  field :encoded_query_params, 5,
    repeated: true,
    type: Connectrpc.Conformance.V1.RawHTTPRequest.EncodedQueryParam,
    json_name: "encodedQueryParams"

  field :unary, 6, type: Connectrpc.Conformance.V1.MessageContents, oneof: 0
  field :stream, 7, type: Connectrpc.Conformance.V1.StreamContents, oneof: 0
end

defmodule Connectrpc.Conformance.V1.MessageContents do
  @moduledoc false

  use Protobuf,
    full_name: "connectrpc.conformance.v1.MessageContents",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  oneof :data, 0

  field :binary, 1, type: :bytes, oneof: 0
  field :text, 2, type: :string, oneof: 0
  field :binary_message, 3, type: Google.Protobuf.Any, json_name: "binaryMessage", oneof: 0
  field :compression, 4, type: Connectrpc.Conformance.V1.Compression, enum: true
end

defmodule Connectrpc.Conformance.V1.StreamContents.StreamItem do
  @moduledoc false

  use Protobuf,
    full_name: "connectrpc.conformance.v1.StreamContents.StreamItem",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :flags, 1, type: :uint32
  field :length, 2, proto3_optional: true, type: :uint32
  field :payload, 3, type: Connectrpc.Conformance.V1.MessageContents
end

defmodule Connectrpc.Conformance.V1.StreamContents do
  @moduledoc false

  use Protobuf,
    full_name: "connectrpc.conformance.v1.StreamContents",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :items, 1, repeated: true, type: Connectrpc.Conformance.V1.StreamContents.StreamItem
end

defmodule Connectrpc.Conformance.V1.RawHTTPResponse do
  @moduledoc false

  use Protobuf,
    full_name: "connectrpc.conformance.v1.RawHTTPResponse",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  oneof :body, 0

  field :status_code, 1, type: :uint32, json_name: "statusCode"
  field :headers, 2, repeated: true, type: Connectrpc.Conformance.V1.Header
  field :unary, 3, type: Connectrpc.Conformance.V1.MessageContents, oneof: 0
  field :stream, 4, type: Connectrpc.Conformance.V1.StreamContents, oneof: 0
  field :trailers, 5, repeated: true, type: Connectrpc.Conformance.V1.Header
end

defmodule Connectrpc.Conformance.V1.ConformanceService.Service do
  @moduledoc false

  use GRPC.Service,
    name: "connectrpc.conformance.v1.ConformanceService",
    protoc_gen_elixir_version: "0.17.1"

  rpc(:Unary, Connectrpc.Conformance.V1.UnaryRequest, Connectrpc.Conformance.V1.UnaryResponse)

  rpc(
    :ServerStream,
    Connectrpc.Conformance.V1.ServerStreamRequest,
    stream(Connectrpc.Conformance.V1.ServerStreamResponse)
  )

  rpc(
    :ClientStream,
    stream(Connectrpc.Conformance.V1.ClientStreamRequest),
    Connectrpc.Conformance.V1.ClientStreamResponse
  )

  rpc(
    :BidiStream,
    stream(Connectrpc.Conformance.V1.BidiStreamRequest),
    stream(Connectrpc.Conformance.V1.BidiStreamResponse)
  )

  rpc(
    :Unimplemented,
    Connectrpc.Conformance.V1.UnimplementedRequest,
    Connectrpc.Conformance.V1.UnimplementedResponse
  )

  rpc(
    :IdempotentUnary,
    Connectrpc.Conformance.V1.IdempotentUnaryRequest,
    Connectrpc.Conformance.V1.IdempotentUnaryResponse,
    %{idempotency_level: :NO_SIDE_EFFECTS}
  )
end

defmodule Connectrpc.Conformance.V1.ConformanceService.Stub do
  @moduledoc false

  use GRPC.Stub, service: Connectrpc.Conformance.V1.ConformanceService.Service
end
