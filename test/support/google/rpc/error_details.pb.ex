defmodule Google.Rpc.ErrorInfo.MetadataEntry do
  @moduledoc false
  use Protobuf, map: true, protoc_gen_elixir_version: "0.14.1", syntax: :proto3

  field :key, 1, type: :string
  field :value, 2, type: :string
end

defmodule Google.Rpc.ErrorInfo do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.14.1", syntax: :proto3

  field :reason, 1, type: :string
  field :domain, 2, type: :string
  field :metadata, 3, repeated: true, type: Google.Rpc.ErrorInfo.MetadataEntry, map: true
end
