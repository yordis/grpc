defmodule Conformance.Service do
  @moduledoc """
  Implementation of `connectrpc.conformance.v1.ConformanceService`.

  Follows the behavior documented for conformance servers: every response
  echoes the observed request (headers, timeout and request messages), and the
  response definition in the request drives headers, trailers, data, delays and
  errors.
  """
  use GRPC.Server,
    service: Connectrpc.Conformance.V1.ConformanceService.Service,
    codecs: [GRPC.Codec.Proto, GRPC.Codec.WebText, GRPC.Codec.JSON],
    compressors: [GRPC.Compressor.Gzip],
    connect: true

  alias Connectrpc.Conformance.V1.{
    BidiStreamResponse,
    ClientStreamResponse,
    ConformancePayload,
    IdempotentUnaryResponse,
    ServerStreamResponse,
    UnaryResponse
  }

  alias Conformance.RequestInfo

  # Unary

  def unary(req, stream) do
    %UnaryResponse{payload: do_unary(req, stream)}
  end

  def idempotent_unary(req, stream) do
    %IdempotentUnaryResponse{payload: do_unary(req, stream)}
  end

  defp do_unary(req, stream) do
    unary_response(req.response_definition, stream, [RequestInfo.to_any(req)])
  end

  # Client streaming

  def client_stream(req_enum, stream) do
    {definition, reqs} =
      Enum.reduce(req_enum, {nil, []}, fn req, {definition, reqs} ->
        definition = if reqs == [], do: req.response_definition, else: definition
        {definition, [RequestInfo.to_any(req) | reqs]}
      end)

    %ClientStreamResponse{payload: unary_response(definition, stream, Enum.reverse(reqs))}
  end

  defp unary_response(nil, stream, reqs) do
    %ConformancePayload{request_info: RequestInfo.build(stream, reqs)}
  end

  defp unary_response(definition, stream, reqs) do
    info = RequestInfo.build(stream, reqs)

    case definition.response do
      {:error, error} ->
        set_headers(stream, definition.response_headers)
        set_trailers(stream, definition.response_trailers)
        sleep(definition.response_delay_ms)
        raise_error(error, [RequestInfo.pack(info)])

      other ->
        data =
          case other do
            {:response_data, data} -> data
            _ -> <<>>
          end

        set_headers(stream, definition.response_headers)
        set_trailers(stream, definition.response_trailers)
        sleep(definition.response_delay_ms)
        %ConformancePayload{data: data, request_info: info}
    end
  end

  # Server streaming

  def server_stream(req, stream) do
    definition = req.response_definition
    any = RequestInfo.to_any(req)

    if definition do
      set_headers(stream, definition.response_headers)
      set_trailers(stream, definition.response_trailers)

      definition.response_data
      |> Enum.with_index()
      |> Enum.each(fn {data, index} ->
        payload = %ConformancePayload{data: data}

        payload =
          if index == 0,
            do: %{payload | request_info: RequestInfo.build(stream, [any])},
            else: payload

        sleep(definition.response_delay_ms)
        GRPC.Server.send_reply(stream, %ServerStreamResponse{payload: payload})
      end)

      if definition.error do
        details =
          if definition.response_data == [],
            do: [RequestInfo.pack(RequestInfo.build(stream, [any]))],
            else: []

        raise_error(definition.error, details)
      end
    end

    :ok
  end

  # Bidirectional streaming

  def bidi_stream(req_enum, stream) do
    state = %{definition: nil, full_duplex: false, first: true, resp_num: 0, reqs: [], info: nil}

    state =
      Enum.reduce_while(req_enum, state, fn req, state ->
        state = %{state | reqs: state.reqs ++ [RequestInfo.to_any(req)]}
        state = if state.first, do: init_bidi(state, req, stream), else: state
        data = (state.definition && state.definition.response_data) || []

        cond do
          not state.full_duplex ->
            {:cont, state}

          state.resp_num >= length(data) ->
            {:halt, state}

          true ->
            {:cont, send_bidi(state, stream)}
        end
      end)

    data = (state.definition && state.definition.response_data) || []

    state =
      Enum.reduce(state.resp_num..(length(data) - 1)//1, state, fn _, state ->
        send_bidi(state, stream)
      end)

    if state.definition && state.definition.error do
      details =
        if state.resp_num == 0,
          do: [RequestInfo.pack(RequestInfo.build(stream, state.reqs))],
          else: []

      raise_error(state.definition.error, details)
    end

    :ok
  end

  defp init_bidi(state, req, stream) do
    definition = req.response_definition
    state = %{state | first: false, definition: definition, full_duplex: req.full_duplex}

    if definition do
      set_headers(stream, definition.response_headers)
      set_trailers(stream, definition.response_trailers)
    end

    state
  end

  defp send_bidi(state, stream) do
    definition = state.definition
    data = Enum.at(definition.response_data, state.resp_num)

    info =
      if state.resp_num == 0,
        do: RequestInfo.build(stream, state.reqs),
        else: %ConformancePayload.RequestInfo{requests: state.reqs}

    sleep(definition.response_delay_ms)

    GRPC.Server.send_reply(stream, %BidiStreamResponse{
      payload: %ConformancePayload{data: data, request_info: info}
    })

    %{state | resp_num: state.resp_num + 1, reqs: []}
  end

  # Unimplemented

  def unimplemented(_req, _stream) do
    raise GRPC.RPCError, status: :unimplemented
  end

  # Helpers

  defp raise_error(error, extra_details) do
    raise GRPC.RPCError,
      status: Conformance.Codes.to_grpc(error.code),
      message: error.message || "",
      details: error.details ++ extra_details
  end

  defp set_headers(_stream, []), do: :ok
  defp set_headers(stream, headers), do: GRPC.Server.set_headers(stream, to_map(headers))

  defp set_trailers(_stream, []), do: :ok
  defp set_trailers(stream, trailers), do: GRPC.Server.set_trailers(stream, to_map(trailers))

  defp to_map(headers) do
    Map.new(headers, fn h -> {String.downcase(h.name), Enum.join(h.value, ", ")} end)
  end

  defp sleep(0), do: :ok
  defp sleep(ms), do: Process.sleep(ms)
end
