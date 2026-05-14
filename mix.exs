defmodule UdsDist.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://gitlab.com/cyberassessmentlabs/public/tools/uds_dist"

  def project do
    [
      app: :uds_dist,
      version: @version,
      language: :erlang,
      elixir: "~> 1.18",
      erlc_options: [:debug_info, :warnings_as_errors],
      erlc_paths: ["src"],
      source_url: @source_url,
      deps: deps()
    ]
  end

  def application do
    [extra_applications: [:kernel]]
  end

  defp deps, do: []
end
