if Code.ensure_loaded?(Jason) do
  defmodule GRPC.Codec.JSON do
    @moduledoc """
    JSON Codec for gRPC communication.

    This module implements the `GRPC.Codec` behaviour, providing encoding and decoding functions
    for JSON serialization in the context of gRPC communication.

    ## Configuration

    By default, the codec uses `emit_unpopulated: true` to include all fields with default values.
    You can override this behavior by:

    1. Passing options to `encode/2`:
       ```elixir
       GRPC.Codec.JSON.encode(struct, emit_unpopulated: false)
       ```

    2. Setting application config:
       ```elixir
       config :grpc, GRPC.Codec.JSON, emit_unpopulated: false
       ```

    This module requires the Jason dependency.
    """
    @behaviour GRPC.Codec

    def name(), do: "json"

    @doc """
    Encodes a struct using the Protobuf.JSON.encode!/2 function.

    By default, uses `emit_unpopulated: true` unless configured otherwise via application config
    or explicitly passed in opts.

    ### Parameters:

    - `struct` - The struct to be encoded.
    - `opts` - Keyword list of options to pass to Protobuf.JSON.encode!/2. Defaults to `[]`.

    ### Returns:

    The encoded binary data.

    ### Examples:

    ```elixir
    # Using default options (from config or emit_unpopulated: true)
    %MyStruct{id: 1, name: "John"} |> GRPC.Codec.JSON.encode()

    # Overriding with custom options
     GRPC.Codec.JSON.encode(%MyStruct{id: 1, name: "John"}, emit_unpopulated: false)
    ```

    """
    def encode(struct, opts \\ []) do
      opts = Keyword.merge(get_default_encode_opts(), opts)
      Protobuf.JSON.encode!(struct, opts)
    end

    defp get_default_encode_opts do
      Application.get_env(:grpc, __MODULE__, emit_unpopulated: true)
    end

    @doc """
    Decodes JSON into a message.

    Given a Protobuf message module, it gives the struct of that module, read with
    the canonical Protobuf JSON mapping (`Protobuf.JSON.decode!/2`). An empty binary
    is the empty message. For any other `module`, such as `nil`, it gives a map
    with string keys, as `Jason.decode!/1` does, and `%{}` for an empty binary.

    Raises if the binary is not valid JSON for the message.

    ## Examples

    ```elixir
    GRPC.Codec.JSON.decode(~s({"name": "John"}), MyStruct)
    #=> %MyStruct{name: "John"}

    GRPC.Codec.JSON.decode(~s({"name": "John"}), nil)
    #=> %{"name" => "John"}
    ```
    """
    def decode(binary, module) do
      if message_module?(module), do: decode_message(binary, module), else: decode_map(binary)
    end

    defp decode_message(<<>>, module), do: Protobuf.JSON.decode!("{}", module)
    defp decode_message(binary, module), do: Protobuf.JSON.decode!(binary, module)

    defp decode_map(<<>>), do: %{}
    defp decode_map(binary), do: Jason.decode!(binary)

    defp message_module?(module) when is_atom(module) and not is_nil(module) do
      Code.ensure_loaded?(module) and function_exported?(module, :__message_props__, 0)
    end

    defp message_module?(_module), do: false
  end
else
  defmodule GRPC.Codec.JSON do
    def decode(_, _), do: raise(ArgumentError, "Module Jason not found")
  end
end
