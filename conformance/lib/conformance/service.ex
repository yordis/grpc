defmodule Conformance.Service do
  @moduledoc false
  use GRPC.Server,
    service: Connectrpc.Conformance.V1.ConformanceService.Service,
    compressors: [GRPC.Compressor.Gzip]

  def unary(_req, _stream), do: unimplemented()
  def idempotent_unary(_req, _stream), do: unimplemented()
  def client_stream(_reqs, _stream), do: unimplemented()
  def server_stream(_req, _stream), do: unimplemented()
  def bidi_stream(_reqs, _stream), do: unimplemented()
  def unimplemented(_req, _stream), do: unimplemented()

  defp unimplemented, do: raise(GRPC.RPCError, status: :unimplemented)
end
