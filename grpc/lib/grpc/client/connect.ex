defmodule GRPC.Client.Connect do
  @moduledoc false
  # The request side of the Connect protocol (https://connectrpc.com/docs/protocol)
  # for a client adapter: the headers and the body of a call.
  #
  # A unary RPC sends its message as the whole body, with the content type
  # `application/<codec>`. Every other RPC kind sends enveloped messages with the
  # content type `application/connect+<codec>`, the same envelope as gRPC.

  alias GRPC.Transport.HTTP2

  @doc "`:unary` for a unary RPC, `:stream` for every other kind."
  def kind(%{grpc_type: :unary}), do: :unary
  def kind(_stream), do: :stream

  @doc "The request headers of a call, without the pseudo headers."
  def request_headers(stream, opts) do
    kind = kind(stream)

    [
      {"content-type", content_type(kind, stream.codec)},
      {"connect-protocol-version", "1"},
      {"user-agent", GRPC.Core.user_agent()}
    ]
    |> append_compression(kind, stream.compressor, stream.accepted_compressors)
    |> append_timeout(opts[:timeout])
    |> append_metadata(stream.channel.headers)
    |> append_metadata(stream.headers)
    |> append_metadata(opts[:metadata])
  end

  @doc "The content type of the messages of a call: `application/proto` or `application/connect+proto`."
  def content_type(:unary, codec), do: "application/" <> codec_name(codec)
  def content_type(:stream, codec), do: "application/connect+" <> codec_name(codec)

  defp codec_name(codec) when is_atom(codec), do: codec.name()
  defp codec_name(%{name: name}), do: name

  @doc "The body of a unary call: the message, compressed as a whole when there is a compressor."
  def unary_body(message, nil), do: message
  def unary_body(message, compressor), do: compressor.compress(message)

  defp append_compression(headers, kind, compressor, accepted) do
    {encoding, accept} =
      case kind do
        :unary -> {"content-encoding", "accept-encoding"}
        :stream -> {"connect-content-encoding", "connect-accept-encoding"}
      end

    headers = if compressor, do: [{encoding, compressor.name()} | headers], else: headers

    case Enum.map(accepted, & &1.name()) do
      [] -> headers
      names -> [{accept, Enum.join(names, ",")} | headers]
    end
  end

  defp append_timeout(headers, timeout) when is_integer(timeout) and timeout >= 0,
    do: [{"connect-timeout-ms", Integer.to_string(timeout)} | headers]

  defp append_timeout(headers, _timeout), do: headers

  defp append_metadata(headers, metadata) when is_map(metadata) or is_list(metadata),
    do: Enum.to_list(HTTP2.encode_metadata(metadata)) ++ headers

  defp append_metadata(headers, _metadata), do: headers
end
