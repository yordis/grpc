defmodule GRPC.Client.ResetCode do
  @moduledoc false

  # What a server RST_STREAM means to a call, the same on every adapter. The status of each
  # HTTP/2 error code is the one of the gRPC HTTP/2 spec (PROTOCOL-HTTP2.md, "Errors").

  # A server enforces the `grpc-timeout` it was sent, counted from when the request reached it,
  # so it never expires before the client's own deadline. A CANCEL reset that arrives once the
  # deadline has passed is that deadline, whichever side notices first. The 1ms is only the
  # millisecond truncation of the two clocks.
  @deadline_tolerance 1

  @doc "Whether a CANCEL reset seen now is the deadline of the call (a monotonic ms)."
  @spec at_deadline?(integer() | nil) :: boolean()
  def at_deadline?(deadline) when is_integer(deadline),
    do: System.monotonic_time(:millisecond) >= deadline - @deadline_tolerance

  def at_deadline?(_deadline), do: false

  @doc "The status of a reset with the HTTP/2 error code, as the atom the HTTP/2 library names it."
  @spec status(atom() | non_neg_integer()) :: non_neg_integer()
  def status(:refused_stream), do: GRPC.Status.unavailable()
  def status(:cancel), do: GRPC.Status.cancelled()
  def status(:enhance_your_calm), do: GRPC.Status.resource_exhausted()
  def status(:inadequate_security), do: GRPC.Status.permission_denied()
  def status(7), do: GRPC.Status.unavailable()
  def status(8), do: GRPC.Status.cancelled()
  def status(11), do: GRPC.Status.resource_exhausted()
  def status(12), do: GRPC.Status.permission_denied()
  def status(_code), do: GRPC.Status.internal()

  @doc "The error of a call whose stream the server reset with `code`."
  @spec error(atom() | non_neg_integer()) :: GRPC.RPCError.t()
  def error(code) do
    GRPC.RPCError.exception(status(code), "stream reset by the server (#{name(code)})")
  end

  defp name(code) when is_atom(code), do: code |> Atom.to_string() |> String.upcase()
  defp name(code), do: "error code #{code}"
end
