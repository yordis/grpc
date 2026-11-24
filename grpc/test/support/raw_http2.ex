defmodule GRPC.Integration.RawHTTP2 do
  @moduledoc """
  Issues a single unary gRPC request over a bare HTTP/2 connection and returns
  the response exactly as it appeared on the wire, so tests can assert on
  header and trailer names, repeated entries and value encoding.
  """

  @doc """
  Returns `%{status: integer, headers: [{name, value}], trailers: [{name, value}], data: binary}`.
  """
  def unary(port, path, message, request_headers \\ []) do
    {:ok, conn} = Mint.HTTP2.connect(:http, "localhost", port)

    headers = [{"content-type", "application/grpc"}, {"te", "trailers"}] ++ request_headers

    {:ok, body, _size} = GRPC.Message.to_data(message)
    {:ok, conn, ref} = Mint.HTTP2.request(conn, "POST", path, headers, body)

    collect(conn, ref, %{status: nil, headers: [], trailers: [], data: ""})
  end

  defp collect(conn, ref, acc) do
    receive do
      message ->
        {:ok, conn, responses} = Mint.HTTP2.stream(conn, message)

        case Enum.reduce(responses, {acc, false}, &handle(&1, &2, ref)) do
          {acc, true} ->
            Mint.HTTP2.close(conn)
            acc

          {acc, false} ->
            collect(conn, ref, acc)
        end
    after
      5_000 -> raise "timed out waiting for the response"
    end
  end

  defp handle({:status, ref, status}, {acc, done}, ref), do: {%{acc | status: status}, done}

  defp handle({:headers, ref, headers}, {acc, done}, ref) do
    if acc.headers == [] do
      {%{acc | headers: headers}, done}
    else
      {%{acc | trailers: acc.trailers ++ headers}, done}
    end
  end

  defp handle({:data, ref, data}, {acc, done}, ref), do: {%{acc | data: acc.data <> data}, done}
  defp handle({:done, ref}, {acc, _}, ref), do: {acc, true}
  defp handle(_, state, _), do: state
end
