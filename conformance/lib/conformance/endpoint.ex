defmodule Conformance.Endpoint do
  @moduledoc false
  use GRPC.Endpoint

  run(Conformance.Service)
end
