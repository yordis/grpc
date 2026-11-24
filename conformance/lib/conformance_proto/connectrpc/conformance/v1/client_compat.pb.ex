defmodule Connectrpc.Conformance.V1.ClientCompatRequest.Cancel do
  @moduledoc false

  use Protobuf,
    full_name: "connectrpc.conformance.v1.ClientCompatRequest.Cancel",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  oneof :cancel_timing, 0

  field :before_close_send, 1, type: Google.Protobuf.Empty, json_name: "beforeCloseSend", oneof: 0
  field :after_close_send_ms, 2, type: :uint32, json_name: "afterCloseSendMs", oneof: 0
  field :after_num_responses, 3, type: :uint32, json_name: "afterNumResponses", oneof: 0
end

defmodule Connectrpc.Conformance.V1.ClientCompatRequest do
  @moduledoc false

  use Protobuf,
    full_name: "connectrpc.conformance.v1.ClientCompatRequest",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :test_name, 1, type: :string, json_name: "testName"

  field :http_version, 2,
    type: Connectrpc.Conformance.V1.HTTPVersion,
    json_name: "httpVersion",
    enum: true

  field :protocol, 3, type: Connectrpc.Conformance.V1.Protocol, enum: true
  field :codec, 4, type: Connectrpc.Conformance.V1.Codec, enum: true
  field :compression, 5, type: Connectrpc.Conformance.V1.Compression, enum: true
  field :host, 6, type: :string
  field :port, 7, type: :uint32
  field :server_tls_cert, 8, type: :bytes, json_name: "serverTlsCert"

  field :client_tls_creds, 9,
    type: Connectrpc.Conformance.V1.TLSCreds,
    json_name: "clientTlsCreds"

  field :message_receive_limit, 10, type: :uint32, json_name: "messageReceiveLimit"
  field :service, 11, proto3_optional: true, type: :string
  field :method, 12, proto3_optional: true, type: :string

  field :stream_type, 13,
    type: Connectrpc.Conformance.V1.StreamType,
    json_name: "streamType",
    enum: true

  field :use_get_http_method, 14, type: :bool, json_name: "useGetHttpMethod"

  field :request_headers, 15,
    repeated: true,
    type: Connectrpc.Conformance.V1.Header,
    json_name: "requestHeaders"

  field :request_messages, 16,
    repeated: true,
    type: Google.Protobuf.Any,
    json_name: "requestMessages"

  field :timeout_ms, 17, proto3_optional: true, type: :uint32, json_name: "timeoutMs"
  field :request_delay_ms, 18, type: :uint32, json_name: "requestDelayMs"
  field :cancel, 19, type: Connectrpc.Conformance.V1.ClientCompatRequest.Cancel
  field :raw_request, 20, type: Connectrpc.Conformance.V1.RawHTTPRequest, json_name: "rawRequest"
end

defmodule Connectrpc.Conformance.V1.ClientCompatResponse do
  @moduledoc false

  use Protobuf,
    full_name: "connectrpc.conformance.v1.ClientCompatResponse",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  oneof :result, 0

  field :test_name, 1, type: :string, json_name: "testName"
  field :response, 2, type: Connectrpc.Conformance.V1.ClientResponseResult, oneof: 0
  field :error, 3, type: Connectrpc.Conformance.V1.ClientErrorResult, oneof: 0
end

defmodule Connectrpc.Conformance.V1.ClientResponseResult do
  @moduledoc false

  use Protobuf,
    full_name: "connectrpc.conformance.v1.ClientResponseResult",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :response_headers, 1,
    repeated: true,
    type: Connectrpc.Conformance.V1.Header,
    json_name: "responseHeaders"

  field :payloads, 2, repeated: true, type: Connectrpc.Conformance.V1.ConformancePayload
  field :error, 3, type: Connectrpc.Conformance.V1.Error

  field :response_trailers, 4,
    repeated: true,
    type: Connectrpc.Conformance.V1.Header,
    json_name: "responseTrailers"

  field :num_unsent_requests, 5, type: :int32, json_name: "numUnsentRequests"
  field :http_status_code, 6, proto3_optional: true, type: :int32, json_name: "httpStatusCode"
  field :feedback, 7, repeated: true, type: :string
end

defmodule Connectrpc.Conformance.V1.ClientErrorResult do
  @moduledoc false

  use Protobuf,
    full_name: "connectrpc.conformance.v1.ClientErrorResult",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :message, 1, type: :string
end

defmodule Connectrpc.Conformance.V1.WireDetails do
  @moduledoc false

  use Protobuf,
    full_name: "connectrpc.conformance.v1.WireDetails",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :actual_status_code, 1, type: :int32, json_name: "actualStatusCode"
  field :connect_error_raw, 2, type: Google.Protobuf.Struct, json_name: "connectErrorRaw"

  field :actual_http_trailers, 3,
    repeated: true,
    type: Connectrpc.Conformance.V1.Header,
    json_name: "actualHttpTrailers"

  field :actual_grpcweb_trailers, 4,
    proto3_optional: true,
    type: :string,
    json_name: "actualGrpcwebTrailers"
end
