defmodule Connectrpc.Conformance.V1.ServerCompatRequest do
  @moduledoc false

  use Protobuf,
    full_name: "connectrpc.conformance.v1.ServerCompatRequest",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :protocol, 1, type: Connectrpc.Conformance.V1.Protocol, enum: true

  field :http_version, 2,
    type: Connectrpc.Conformance.V1.HTTPVersion,
    json_name: "httpVersion",
    enum: true

  field :use_tls, 4, type: :bool, json_name: "useTls"
  field :client_tls_cert, 5, type: :bytes, json_name: "clientTlsCert"
  field :message_receive_limit, 6, type: :uint32, json_name: "messageReceiveLimit"
  field :server_creds, 7, type: Connectrpc.Conformance.V1.TLSCreds, json_name: "serverCreds"
end

defmodule Connectrpc.Conformance.V1.ServerCompatResponse do
  @moduledoc false

  use Protobuf,
    full_name: "connectrpc.conformance.v1.ServerCompatResponse",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :host, 1, type: :string
  field :port, 2, type: :uint32
  field :pem_cert, 3, type: :bytes, json_name: "pemCert"
end
