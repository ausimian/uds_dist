defmodule UdsDist.MixProject do
  use Mix.Project

  @version "1.0.0-rc.1"
  @source_url "https://github.com/ausimian/uds_dist"

  def project do
    [
      app: :uds_dist,
      version: System.get_env("VERSION_OVERRIDE", @version),
      language: :erlang,
      elixir: "~> 1.18",
      erlc_options: [:debug_info, :warnings_as_errors],
      erlc_paths: ["src"],
      consolidate_protocols: false,
      source_url: @source_url,
      description: description(),
      package: package(),
      docs: docs(),
      deps: deps(),
      test_coverage: [summary: [threshold: 70]]
    ]
  end

  def application do
    [extra_applications: [:kernel], env: [backlog: 5]]
  end

  defp description do
    "Erlang distribution over Unix domain sockets via the :socket module, " <>
      "with optional Linux abstract namespace support."
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(src mix.exs LICENSE CHANGELOG.md RELEASE.md README.md)
    ]
  end

  defp docs do
    [
      source_ref: @version,
      source_url: @source_url,
      main: "readme",
      extras: ["README.md", "CHANGELOG.md", "LICENSE"]
    ]
  end

  defp deps do
    [
      {:ex_doc, ">= 0.0.0", only: :dev, runtime: false},
      {:publisho, "~> 1.0", only: :dev, runtime: false}
    ]
  end
end
