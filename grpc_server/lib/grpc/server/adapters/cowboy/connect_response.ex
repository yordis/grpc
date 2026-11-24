defmodule GRPC.Server.Adapters.Cowboy.ConnectResponse do
  @moduledoc false
  # The response side of the Connect protocol for `GRPC.Server.Adapters.Cowboy.Handler`.
  # Every function takes the cowboy request and the handler state, and returns what the
  # handler's `info/3` returns.

  alias GRPC.RPCError
  alias GRPC.Server.Connect
  alias GRPC.Transport.HTTP2

  @doc """
  A unary reply is held until the call ends, because its trailers are sent
  as headers, ahead of the body.
  """
  def stream_body(data, _opts, _is_fin, req, state) do
    {:ok, req, Map.put(state, :connect_body, data)}
  end

  @doc """
  Handlers send headers before they reply. A unary response sends its headers with its body.
  """
  def stream_reply(_status, headers, req, state) do
    {:ok, :cowboy_req.set_resp_headers(headers, req), Map.put(state, :custom_resp_headers?, true)}
  end

  @doc """
  The end of a successful call: sends the held reply, with the trailers as headers.
  """
  def stream_trailers(req, state) do
    body = Map.get(state, :connect_body, "")
    req = :cowboy_req.reply(200, trailer_headers(state), body, req)
    {:ok, req, state}
  end

  @doc """
  Replies with the error. The trailers set so far go along as headers.
  """
  def send_error(req, %RPCError{} = error, state) do
    headers = Map.put(trailer_headers(state), "content-type", "application/json")
    :cowboy_req.reply(Connect.status_line(error.status), headers, Connect.error_body(error), req)
  end

  # The trailers of a unary response are headers with the prefix `trailer-`.
  defp trailer_headers(state) do
    state
    |> Map.get(:resp_trailers, %{})
    |> HTTP2.encode_metadata()
    |> Map.new(fn {name, value} -> {"trailer-" <> name, value} end)
  end
end
