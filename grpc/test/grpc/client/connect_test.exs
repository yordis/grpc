defmodule GRPC.Client.ConnectTest do
  use ExUnit.Case, async: true

  alias GRPC.Client.Connect

  defp stream(compressor) do
    %{path: "/helloworld.Reader/Read", codec: GRPC.Codec.Proto, compressor: compressor}
  end

  defp query_keys(path) do
    [_path, query] = String.split(path, "?")
    query |> String.split("&") |> Enum.map(&(&1 |> String.split("=") |> hd()))
  end

  describe "get_path/3" do
    test "puts the query parameters in the order that caches like" do
      path = Connect.get_path(stream(nil), "message", [])

      assert query_keys(path) == ["connect", "base64", "encoding", "message"]
    end

    test "names the compression between base64 and encoding" do
      path = Connect.get_path(stream(GRPC.Compressor.Gzip), "message", [])

      assert query_keys(path) == ["connect", "base64", "compression", "encoding", "message"]
    end
  end
end
