defmodule Conformance.Main do
  @moduledoc """
  Implements the runner handshake: reads a size-delimited `ServerCompatRequest`
  from stdin, starts the server, and writes a size-delimited
  `ServerCompatResponse` to stdout.
  """

  alias Connectrpc.Conformance.V1.{ServerCompatRequest, ServerCompatResponse}

  def run do
    request = read_request()
    {port, pem_cert} = start_server(request)

    response = %ServerCompatResponse{host: "127.0.0.1", port: port, pem_cert: pem_cert}
    bin = ServerCompatResponse.encode(response)
    :ok = Conformance.Protocol.write(bin)
  end

  defp read_request do
    input = Conformance.Protocol.open_input()
    ServerCompatRequest.decode(Conformance.Protocol.read(input))
  end

  defp start_server(request) do
    # The library bounds each received message by this application setting.
    case request.message_receive_limit do
      0 -> :ok
      limit -> Application.put_env(:grpc, :max_message_length, limit)
    end

    {opts, pem_cert} = tls_opts(request)

    {:ok, _pid, port} =
      GRPC.Server.start_endpoint(Conformance.Endpoint, 0, adapter_opts: opts)

    {port, pem_cert}
  end

  defp tls_opts(%ServerCompatRequest{use_tls: false}), do: {[], <<>>}

  defp tls_opts(%ServerCompatRequest{server_creds: %{cert: cert, key: key}} = request) do
    dir = tls_dir()
    File.mkdir_p!(dir)
    certfile = Path.join(dir, "cert.pem")
    keyfile = Path.join(dir, "key.pem")
    File.write!(certfile, cert)
    File.write!(keyfile, key)
    File.chmod!(keyfile, 0o600)

    ssl = [certfile: certfile, keyfile: keyfile] ++ client_cert_opts(request.client_tls_cert)
    {[cred: GRPC.Credential.new(ssl: ssl)], cert}
  end

  # The runner starts several servers at once, each its own OS process, and a unique
  # integer alone repeats across them: two servers shared a directory, and one loaded
  # the other's certificate and key.
  @doc false
  def tls_dir do
    name = "conformance-#{System.pid()}-#{System.unique_integer([:positive])}"
    Path.join(System.tmp_dir!(), name)
  end

  defp client_cert_opts(<<>>), do: []

  defp client_cert_opts(pem),
    do: [fail_if_no_peer_cert: true] ++ Conformance.PinnedCert.ssl_opts(pem)
end
