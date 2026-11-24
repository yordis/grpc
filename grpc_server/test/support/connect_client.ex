defmodule GRPC.Test.ConnectClient do
  @moduledoc """
  Sends one HTTP request to a running server and returns the response as it came off the
  wire: status, headers, body and trailers. Used to test the Connect protocol over
  HTTP/1.1 (`:http`) and HTTP/2 (`:http2`, cleartext with prior knowledge).
  """

  @doc """
  Returns `%{status: integer, headers: [{name, value}], body: binary, trailers: [{name, value}]}`.
  """
  def request(port, version, method, path, headers, body \\ "") do
    {:ok, conn} = :gun.open(~c"localhost", port, %{protocols: [version], retry: 0})
    {:ok, _protocol} = :gun.await_up(conn, 5_000)

    try do
      ref = send_request(conn, method, path, headers, body)
      collect(conn, ref, %{status: nil, headers: [], body: "", trailers: []})
    after
      :gun.close(conn)
    end
  end

  def header(response, name) do
    case List.keyfind(response.headers, name, 0) do
      {_, value} -> value
      nil -> nil
    end
  end

  defp send_request(conn, "GET", path, headers, _body), do: :gun.get(conn, path, headers)

  defp send_request(conn, method, path, headers, body) do
    :gun.request(conn, method, path, headers, body)
  end

  defp collect(conn, ref, acc) do
    case :gun.await(conn, ref, 5_000) do
      {:response, :fin, status, headers} ->
        %{acc | status: status, headers: headers}

      {:response, :nofin, status, headers} ->
        collect(conn, ref, %{acc | status: status, headers: headers})

      {:data, :nofin, data} ->
        collect(conn, ref, %{acc | body: acc.body <> data})

      {:data, :fin, data} ->
        %{acc | body: acc.body <> data}

      {:trailers, trailers} ->
        %{acc | trailers: trailers}

      other ->
        raise "unexpected response: #{inspect(other)}"
    end
  end
end
