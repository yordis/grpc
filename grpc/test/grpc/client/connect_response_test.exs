defmodule GRPC.Client.Connect.ResponseTest do
  use ExUnit.Case, async: true

  alias GRPC.Client.Connect.Response

  defp response(grpc_type, opts \\ []) do
    Response.new(%{
      grpc_type: grpc_type,
      codec: GRPC.Codec.Proto,
      response_mod: Helloworld.HelloReply,
      compressor: nil,
      accepted_compressors: Keyword.get(opts, :accepted_compressors, [])
    })
  end

  defp feed(response, events) do
    Enum.reduce(events, {response, []}, fn event, {response, items} ->
      {response, new_items, _action} = Response.consume(response, event)
      {response, items ++ new_items}
    end)
  end

  defp envelope(flag, payload), do: <<flag::8, byte_size(payload)::32, payload::binary>>

  describe "the error of a unary response" do
    test "takes its code from the HTTP status when the JSON has none" do
      for body <- [
            ~s({"message":"oops"}),
            ~s({"code":null,"message":"oops"}),
            ~s({"code":"nope","message":"oops"})
          ] do
        {_response, items} =
          feed(response(:unary), [
            {:status, 401},
            {:headers, [{"content-type", "application/json"}]},
            {:data, body},
            :done
          ])

        assert {:error, %GRPC.RPCError{status: 16, message: "oops"}} = List.last(items)
      end
    end

    test "is read from a compressed body" do
      body = GRPC.Compressor.Gzip.compress(~s({"code":"out_of_range","message":"oops"}))

      {_response, items} =
        feed(response(:unary, accepted_compressors: [GRPC.Compressor.Gzip]), [
          {:status, 422},
          {:headers, [{"content-type", "application/json"}, {"content-encoding", "gzip"}]},
          {:data, body},
          :done
        ])

      assert {:error, %GRPC.RPCError{status: 11, message: "oops"}} = List.last(items)
    end

    test "carries the headers and the trailers of the response" do
      {_response, items} =
        feed(response(:unary), [
          {:status, 404},
          {:headers,
           [
             {"content-type", "application/json"},
             {"x-header", "h"},
             {"trailer-x-trailer", "t"}
           ]},
          {:data, ~s({"code":"not_found"})},
          :done
        ])

      assert {:error,
              %GRPC.RPCError{
                status: 5,
                headers: %{"x-header" => "h"},
                trailers: %{"x-trailer" => "t"}
              }} = List.last(items)
    end

    test "is unknown when a successful response is not a Connect one" do
      {_response, items} =
        feed(response(:unary), [
          {:status, 200},
          {:headers, [{"content-type", "image/jpeg"}]},
          {:data, "12345678"},
          :done
        ])

      assert {:error, %GRPC.RPCError{status: 2}} = List.last(items)
    end
  end

  describe "the end of a stream" do
    test "is unknown when the error has no code" do
      end_stream = envelope(2, ~s({"error":{"message":"oops"}}))

      {_response, items} =
        feed(response(:server_stream), [
          {:status, 200},
          {:headers, [{"content-type", "application/connect+proto"}]},
          {:data, end_stream},
          :done
        ])

      assert {:error, %GRPC.RPCError{status: 2, message: "oops"}} = List.last(items)
    end

    test "is read from a compressed envelope" do
      end_stream =
        envelope(3, GRPC.Compressor.Gzip.compress(~s({"error":{"code":"out_of_range"}})))

      {_response, items} =
        feed(response(:server_stream, accepted_compressors: [GRPC.Compressor.Gzip]), [
          {:status, 200},
          {:headers,
           [
             {"content-type", "application/connect+proto"},
             {"connect-content-encoding", "gzip"}
           ]},
          {:data, end_stream},
          :done
        ])

      assert {:error, %GRPC.RPCError{status: 11}} = List.last(items)
    end
  end
end
