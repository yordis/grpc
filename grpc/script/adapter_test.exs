alias GRPC.Client.Adapters.Gun
alias GRPC.Client.Adapters.Mint
alias GRPC.Channel
alias GRPC.Credential

require Logger

{adapter_to_test, dependency} =
  case System.argv() do
    ["gun" | _rest] -> {Gun, :gun}
    ["mint" | _rest] -> {Mint, :mint}
  end

Mix.install([
  dependency,
  {:grpc, path: Path.join(__DIR__, "..")},
  {:grpc_core, path: Path.join(__DIR__, "../../grpc_core"), override: true},
  {:grpc_server, path: Path.join(__DIR__, "../../grpc_server")}
])

defmodule FeatureServer.Service do
  use GRPC.Service, name: "FeatureServer", protoc_gen_elixir_version: "0.16.0"
end

defmodule FeatureServer do
  use GRPC.Server, service: FeatureServer.Service
end

supported_adapters = [Gun, Mint]

Logger.info("Testing #{adapter_to_test}...")

# The certificate is generated on every run, so there is no committed one to expire.
build_credential = fn ->
  dir = Path.join(System.tmp_dir!(), "grpc_adapter_test_#{System.unique_integer([:positive])}")
  File.mkdir_p!(dir)

  %{server_config: server} =
    :public_key.pkix_test_data(%{
      server_chain: %{
        root: [key: {:rsa, 2048, 65_537}],
        peer: [key: {:rsa, 2048, 65_537}]
      },
      client_chain: %{root: [key: {:rsa, 2048, 65_537}], peer: [key: {:rsa, 2048, 65_537}]}
    })

  write_pem = fn name, type, der ->
    path = Path.join(dir, name)
    File.write!(path, :public_key.pem_encode([{type, der, :not_encrypted}]))
    path
  end

  {key_type, key_der} = server[:key]

  struct(
    Credential,
    ssl: [
      certfile: write_pem.("server.pem", :Certificate, server[:cert]),
      keyfile: write_pem.("server.key", key_type, key_der),
      versions: [:"tlsv1.2", :"tlsv1.3"]
    ]
  )
end

server_credential = build_credential.()

server_opts = %{
  gun: [adapter_opts: [cred: server_credential]],
  mint: []
}

build_channel = fn adapter, port ->
  struct(
    Channel,
    host: "localhost",
    port: port,
    scheme: "http",
    cred: server_credential,
    adapter: adapter,
    adapter_payload: %{},
    codec: GRPC.Codec.Proto,
    interceptors: [],
    compressor: nil,
    accepted_compressors: [],
    headers: []
  )
end

{:ok, _, port} = GRPC.Server.start(FeatureServer, 0, Map.get(server_opts, dependency, []))

for adapter <- supported_adapters do
  channel = build_channel.(adapter, port)

  if adapter == adapter_to_test do
    {:ok, _} = adapter.connect(channel, [])
  else
    try do
      {:ok, _} = adapter.connect(channel, [])
      raise "#{adapter} should not be available!"
    rescue
      UndefinedFunctionError ->
        :ok

      e ->
        :ok = GRPC.Server.stop(FeatureServer)
        raise e
    after
    end
  end
end

Logger.info("Success!")
:ok = GRPC.Server.stop(FeatureServer)
