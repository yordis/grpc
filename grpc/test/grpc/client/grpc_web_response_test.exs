defmodule GRPC.Client.GrpcWeb.ResponseTest do
  use ExUnit.Case, async: true

  alias GRPC.Client.GrpcWeb.Response

  defp response(opts \\ []) do
    Response.new(%{
      codec: GRPC.Codec.Proto,
      response_mod: Helloworld.HelloReply,
      compressor: nil,
      accepted_compressors: Keyword.get(opts, :accepted_compressors, [])
    })
  end

  defp feed(response, events) do
    Enum.reduce(events, {response, [], :ok}, fn event, {response, items, action} ->
      {response, new_items, new_action} = Response.consume(response, event)
      {response, items ++ new_items, if(new_action == :ok, do: action, else: new_action)}
    end)
  end

  defp envelope(flag, payload), do: <<flag::8, byte_size(payload)::32, payload::binary>>

  @headers [{"content-type", "application/grpc-web+proto"}, {"x-custom-header", "h"}]

  defp reply(message) do
    Helloworld.HelloReply.encode(%Helloworld.HelloReply{message: message})
  end

  describe "a trailers-only response" do
    test "is the error in its headers" do
      {_response, items, :ok} =
        feed(response(), [
          {:status, 200},
          {:headers,
           [
             {"content-type", "application/grpc-web+proto"},
             {"grpc-status", "10"},
             {"grpc-message", "aborted"},
             {"x-custom-trailer", "t"}
           ]},
          :done
        ])

      assert [
               {:error,
                %GRPC.RPCError{status: 10, message: "aborted", headers: headers, trailers: trailers}}
             ] = items

      assert trailers["x-custom-trailer"] == "t"
      assert headers == trailers
    end

    test "that succeeded is both the headers and the trailers" do
      {_response, items, :ok} =
        feed(response(), [
          {:status, 200},
          {:headers,
           [
             {"content-type", "application/grpc-web+proto"},
             {"grpc-status", "0"},
             {"x-custom-trailer", "t"}
           ]},
          :done
        ])

      assert [{:headers, %{"x-custom-trailer" => "t"} = headers}, {:trailers, trailers}] = items
      assert headers == trailers
    end

    test "is the error in the headers when an empty data frame ends the response" do
      {_response, items, :ok} =
        feed(response(), [
          {:status, 200},
          {:headers, [{"grpc-status", "10"}, {"grpc-message", "aborted"}]},
          {:data, <<>>},
          :done
        ])

      assert [{:error, %GRPC.RPCError{status: 10, message: "aborted"}}] = items
    end

    test "is the error in the trailers of the HTTP message when the body is empty" do
      {_response, items, :ok} =
        feed(response(), [
          {:status, 200},
          {:headers, @headers},
          {:headers, [{"grpc-status", "10"}, {"grpc-message", "aborted"}]},
          :done
        ])

      assert [
               {:headers, %{"x-custom-header" => "h"}},
               {:error, %GRPC.RPCError{status: 10, message: "aborted"}}
             ] = items
    end
  end

  describe "the trailers envelope" do
    test "ends the response with the trailers" do
      body =
        envelope(0, reply("hi")) <>
          envelope(0x80, "grpc-status: 0\r\ngrpc-message: \r\nx-custom-trailer: t\r\n")

      {_response, items, :ok} =
        feed(response(), [{:status, 200}, {:headers, @headers}, {:data, body}, :done])

      assert [
               {:headers, %{"x-custom-header" => "h"}},
               {:ok, %Helloworld.HelloReply{message: "hi"}},
               {:trailers, %{"grpc-status" => "0", "x-custom-trailer" => "t"}}
             ] = items
    end

    test "carries the error of the call" do
      body = envelope(0x80, "grpc-status: 5\r\ngrpc-message: gone%20away\r\n")

      {_response, items, :ok} =
        feed(response(), [{:status, 200}, {:headers, @headers}, {:data, body}, :done])

      assert [
               {:headers, _},
               {:error, %GRPC.RPCError{status: 5, message: "gone away", headers: headers}}
             ] = items

      assert headers["x-custom-header"] == "h"
    end

    test "split over the chunks of the body" do
      body = envelope(0, reply("hi")) <> envelope(0x80, "grpc-status: 0\r\n")
      <<first::binary-size(3), second::binary-size(9), rest::binary>> = body

      {_response, items, :ok} =
        feed(response(), [
          {:status, 200},
          {:headers, @headers},
          {:data, first},
          {:data, second},
          {:data, rest},
          :done
        ])

      assert [{:headers, _}, {:ok, %{message: "hi"}}, {:trailers, _}] = items
    end

    test "missing from the body is an internal error" do
      {_response, items, :ok} =
        feed(response(), [
          {:status, 200},
          {:headers, @headers},
          {:data, envelope(0, reply("hi"))},
          :done
        ])

      assert [
               {:headers, _},
               {:ok, _},
               {:error, %GRPC.RPCError{status: 13, message: "Missing grpc-status" <> _}}
             ] = items
    end

    test "cut in the middle of a message is an internal error" do
      <<cut::binary-size(7), _::binary>> = envelope(0, reply("hello"))

      {_response, items, :ok} =
        feed(response(), [{:status, 200}, {:headers, @headers}, {:data, cut}, :done])

      assert [{:headers, _}, {:error, %GRPC.RPCError{status: 13, message: "The response ended" <> _}}] =
               items
    end
  end

  describe "a response that is not a 200" do
    test "takes its code from the HTTP status" do
      {_response, items, :ok} =
        feed(response(), [
          {:status, 502},
          {:headers, [{"content-type", "text/plain"}]},
          {:data, "bad gateway"},
          :done
        ])

      assert [{:error, %GRPC.RPCError{status: 14}}] = items
    end

    test "takes its code from the grpc-status when the headers have one" do
      {_response, items, :ok} =
        feed(response(), [
          {:status, 503},
          {:headers, [{"grpc-status", "8"}, {"grpc-message", "full"}]},
          :done
        ])

      assert [{:error, %GRPC.RPCError{status: 8, message: "full"}}] = items
    end
  end

  test "a content type that is not gRPC-Web is an unknown error" do
    {_response, items, :ok} =
      feed(response(), [
        {:status, 200},
        {:headers, [{"content-type", "application/json"}]},
        {:data, "{}"},
        :done
      ])

    assert [{:headers, _}, {:error, %GRPC.RPCError{status: 2}}] = items
  end

  test "a message over the size limit cancels the request" do
    limit = GRPC.Client.MessageLimit.max_message_length()
    prefix = <<0::8, limit + 1::32>>

    {_response, [_headers, {:error, error}], :cancel} =
      feed(response(), [{:status, 200}, {:headers, @headers}, {:data, prefix}])

    assert error.status == 8
  end
end
