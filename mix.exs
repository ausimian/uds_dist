defmodule UdsDist.MixProject do
  use Mix.Project

  @version "2.0.0"
  @source_url "https://github.com/ausimian/uds_dist"

  def project do
    [
      app: :uds_dist,
      version: System.get_env("VERSION_OVERRIDE", @version),
      language: :erlang,
      elixir: "~> 1.18",
      compilers: [:elixir_make] ++ Mix.compilers(),
      make_clean: ["clean"],
      erlc_options: [:debug_info, :warnings_as_errors],
      erlc_paths: ["src"],
      consolidate_protocols: false,
      source_url: @source_url,
      description: description(),
      package: package(),
      docs: docs(),
      deps: deps(),
      aliases: aliases(),
      test_coverage: [summary: [threshold: 70]]
    ]
  end

  def cli do
    [preferred_envs: [precommit: :test]]
  end

  def application do
    [env: [backlog: 5]]
  end

  defp description do
    "Erlang distribution over Unix domain sockets via the :socket module, " <>
      "with optional Linux abstract namespace support."
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(c_src src Makefile mix.exs LICENSE CHANGELOG.md RELEASE.md README.md)
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
      {:elixir_make, "~> 0.10.0", runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ex_doc, ">= 0.0.0", only: :dev, runtime: false},
      {:publisho, "~> 1.0", only: :dev, runtime: false}
    ]
  end

  defp aliases do
    [
      precommit: [
        "compile --warnings-as-errors",
        "deps.unlock --unused",
        "format",
        "credo --strict",
        "test"
      ]
    ]
  end
end
