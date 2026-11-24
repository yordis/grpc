defmodule Conformance.MixProject do
  use Mix.Project

  def project do
    [
      app: :conformance,
      version: "0.1.0",
      elixir: "~> 1.17",
      start_permanent: true,
      deps: deps()
    ]
  end

  def application do
    [extra_applications: [:logger, :crypto, :public_key]]
  end

  defp deps do
    [
      {:grpc_server, path: "../grpc_server", override: true},
      {:grpc, path: "../grpc", override: true},
      {:protobuf, "~> 0.17"},
      {:jason, "~> 1.4"}
    ]
  end
end
