defmodule Conformance.JSONCodec do
  @moduledoc """
  Protobuf JSON codec registered under the `json` name.

  `GRPC.Codec.JSON.decode/2` returns a plain map rather than the request
  struct (it is meant for HTTP transcoding), so it cannot serve `application/grpc+json`
  requests. This codec decodes with `Protobuf.JSON`. Set
  `CONFORMANCE_JSON_CODEC=library` to use the library codec unchanged and
  measure its behavior instead.
  """
  @behaviour GRPC.Codec

  def name, do: "json"

  def encode(struct, opts \\ []), do: GRPC.Codec.JSON.encode(struct, opts)

  def decode(binary, module) do
    if System.get_env("CONFORMANCE_JSON_CODEC") == "library" do
      GRPC.Codec.JSON.decode(binary, module)
    else
      Protobuf.JSON.decode!(binary, module)
    end
  end
end
