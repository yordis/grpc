defmodule Conformance.Codes do
  @moduledoc false

  # Maps the conformance `Code` enum to gRPC status integers.
  @codes %{
    CODE_UNSPECIFIED: 0,
    CODE_CANCELED: 1,
    CODE_UNKNOWN: 2,
    CODE_INVALID_ARGUMENT: 3,
    CODE_DEADLINE_EXCEEDED: 4,
    CODE_NOT_FOUND: 5,
    CODE_ALREADY_EXISTS: 6,
    CODE_PERMISSION_DENIED: 7,
    CODE_RESOURCE_EXHAUSTED: 8,
    CODE_FAILED_PRECONDITION: 9,
    CODE_ABORTED: 10,
    CODE_OUT_OF_RANGE: 11,
    CODE_UNIMPLEMENTED: 12,
    CODE_INTERNAL: 13,
    CODE_UNAVAILABLE: 14,
    CODE_DATA_LOSS: 15,
    CODE_UNAUTHENTICATED: 16
  }

  def to_grpc(code) when is_atom(code), do: Map.fetch!(@codes, code)
  def to_grpc(code) when is_binary(code), do: code |> String.to_existing_atom() |> to_grpc()
end
