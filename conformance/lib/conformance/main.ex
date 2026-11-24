defmodule Conformance.Main do
  @moduledoc """
  Implements the runner handshake: reads a size-delimited `ServerCompatRequest`
  from stdin, starts the server, and writes a size-delimited
  `ServerCompatResponse` to stdout.
  """

  alias Connectrpc.Conformance.V1.{ServerCompatRequest, ServerCompatResponse}

  def run do
    # Treat stdin/stdout as raw bytes: the default device re-encodes as UTF-8.
    :ok = :io.setopts(:standard_io, [:binary, encoding: :latin1])

    request = read_request()
    {port, pem_cert} = start_server(request)

    response = %ServerCompatResponse{host: "127.0.0.1", port: port, pem_cert: pem_cert}
    bin = ServerCompatResponse.encode(response)
    :ok = IO.binwrite(:stdio, <<byte_size(bin)::32-big, bin::binary>>)
  end

  defp read_request do
    <<size::32-big>> = read_exactly(4)
    ServerCompatRequest.decode(read_exactly(size))
  end

  defp read_exactly(0), do: <<>>

  defp read_exactly(n) do
    case IO.binread(:stdio, n) do
      data when is_binary(data) and byte_size(data) == n -> data
      other -> raise "short read from stdin: #{inspect(other)}"
    end
  end

  defp start_server(request) do
    {opts, pem_cert} = tls_opts(request)

    {:ok, _pid, port} =
      GRPC.Server.start_endpoint(Conformance.Endpoint, 0,
        adapter_opts: opts,
        max_body_size: nil
      )

    {port, pem_cert}
  end

  defp tls_opts(%ServerCompatRequest{use_tls: false}), do: {[], <<>>}
end
