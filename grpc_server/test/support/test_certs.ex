defmodule GRPC.TestCerts do
  @moduledoc false
  # Builds the TLS fixtures once per test run, so no committed certificate can
  # expire under the suite. `init/0` runs from `test_helper.exs`, before any
  # test starts.
  #
  # The server certificate is valid for `localhost`, `my-service.local` and
  # `127.0.0.1`, so a client that verifies the peer connects to any of them.
  # The client chain is separate, for the tests that use mTLS.

  @key {:rsa, 2048, 65_537}
  @key_prefix {__MODULE__, :files}

  def init do
    dir = Path.join(System.tmp_dir!(), "grpc_test_certs_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    ExUnit.after_suite(fn _ -> File.rm_rf(dir) end)
    :persistent_term.put(@key_prefix, write_certs(dir))
  end

  @doc "Paths of the generated files: server, client and the CA each side trusts."
  def files, do: :persistent_term.get(@key_prefix)

  @doc "A credential for a server that does not ask the client for a certificate."
  def server_credential(extra \\ []) do
    files = files()

    %GRPC.Credential{
      ssl:
        Keyword.merge(
          [
            certfile: files.server_cert,
            keyfile: files.server_key,
            versions: [:"tlsv1.2", :"tlsv1.3"]
          ],
          extra
        )
    }
  end

  @doc "A credential for a client that verifies the server against the generated CA."
  def client_credential(extra \\ []) do
    files = files()

    %GRPC.Credential{
      ssl:
        Keyword.merge(
          [
            cacertfile: files.server_ca,
            verify: :verify_peer,
            versions: [:"tlsv1.2", :"tlsv1.3"]
          ],
          extra
        )
    }
  end

  defp write_certs(dir) do
    san =
      {:Extension, {2, 5, 29, 17}, false,
       [
         dNSName: ~c"localhost",
         dNSName: ~c"my-service.local",
         iPAddress: <<127, 0, 0, 1>>
       ]}

    %{server_config: server, client_config: client} =
      :public_key.pkix_test_data(%{
        server_chain: %{root: [key: @key], peer: [key: @key, extensions: [san]]},
        client_chain: %{root: [key: @key], peer: [key: @key]}
      })

    %{
      server_cert: write_cert(dir, "server.pem", server[:cert]),
      server_key: write_key(dir, "server.key", server[:key]),
      client_ca: write_cert(dir, "client_ca.pem", hd(server[:cacerts])),
      client_cert: write_cert(dir, "client.pem", client[:cert]),
      client_key: write_key(dir, "client.key", client[:key]),
      server_ca: write_cert(dir, "server_ca.pem", hd(client[:cacerts]))
    }
  end

  defp write_cert(dir, name, der) do
    path = Path.join(dir, name)
    File.write!(path, :public_key.pem_encode([{:Certificate, der, :not_encrypted}]))
    path
  end

  defp write_key(dir, name, {type, der}) do
    path = Path.join(dir, name)
    File.write!(path, :public_key.pem_encode([{type, der, :not_encrypted}]))
    path
  end
end
