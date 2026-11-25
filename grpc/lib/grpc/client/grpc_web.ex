defmodule GRPC.Client.GrpcWeb do
  @moduledoc false
  # The request side of the gRPC-Web protocol
  # (https://github.com/grpc/grpc/blob/master/doc/PROTOCOL-WEB.md) for a client adapter.
  #
  # The messages are enveloped as in gRPC, and the content type is
  # `application/grpc-web+<codec>`. gRPC-Web runs over HTTP/1.1 and HTTP/2, so a request
  # has no `te: trailers` header: the trailers of the response come in its body.

  @doc "The request headers of a call, without the pseudo headers."
  def request_headers(stream, opts) do
    opts = Keyword.put(opts, :content_type, content_type(stream.codec))

    stream
    |> GRPC.Transport.HTTP2.client_headers_without_reserved(opts)
    |> Enum.reject(fn {name, _value} -> name == "te" end)
    |> then(&[{"x-grpc-web", "1"} | &1])
  end

  @doc "The content type of the messages of a call, like `application/grpc-web+proto`."
  def content_type(codec) when is_atom(codec), do: "application/grpc-web+" <> codec.name()
  def content_type(%{name: name}), do: "application/grpc-web+" <> name
end
