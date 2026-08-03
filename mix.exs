defmodule Timetable.MixProject do
  use Mix.Project

  @version "0.1.0"

  def project do
    [
      app: :timetable,
      version: @version,
      name: "Timetable",
      source_url: "https://github.com/elixir-tempo/timetable",
      docs: docs(),
      deps: deps(),
      description: description(),
      package: package(),
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      dialyzer: [
        flags: [
          :error_handling,
          :unknown,
          :underspecs,
          :extra_return,
          :missing_return
        ]
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  def description do
    "Resource-constrained scheduling for Tempo — named resources with " <>
      "attributes, places that contain them, the requirements a session " <>
      "places on them, and the allocation ledger that keeps it all true."
  end

  def package do
    [
      maintainers: ["Kip Cole"],
      licenses: ["Apache-2.0"],
      links: links(),
      files: [
        "lib",
        "mix.exs",
        "README*",
        "CHANGELOG*",
        "LICENSE*"
      ]
    ]
  end

  def links do
    %{
      "GitHub" => "https://github.com/elixir-tempo/timetable",
      "Readme" => "https://github.com/elixir-tempo/timetable/blob/v#{@version}/README.md",
      "Changelog" => "https://github.com/elixir-tempo/timetable/blob/v#{@version}/CHANGELOG.md"
    }
  end

  def docs do
    [
      source_ref: "v#{@version}",
      main: "readme",
      extras:
        [
          "README.md",
          "guides/getting-started.md",
          "LICENSE.md",
          "CHANGELOG.md"
        ] ++ (Path.wildcard("guides/*.md") -- ["guides/getting-started.md"]),
      formatters: ["html", "markdown"],
      groups_for_modules: groups_for_modules(),
      groups_for_extras: groups_for_extras(),
      skip_undefined_reference_warnings_on: ["CHANGELOG.md"] ++ Path.wildcard("guides/*.md")
    ]
  end

  def groups_for_extras do
    ["Case studies": Path.wildcard("guides/case-study-*.md")]
  end

  def groups_for_modules do
    [
      Core: ~r/^Timetable$/,
      "Resources and places": ~r/^Timetable\.(Resource|Place)$/,
      "Requirements and matching": ~r/^Timetable\.(Requirement|Predicate)$/
    ]
  end

  defp deps do
    [
      {:ex_tempo, "~> 1.1"},
      {:ex_doc, "~> 0.38", only: [:dev, :test, :release], optional: true, runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:stream_data, "~> 1.0", only: [:dev, :test], runtime: false},
      # A real IANA database, so tests exercise zone and DST arithmetic
      # rather than Elixir's UTC-only default. Consumers pick their own.
      {:tz, "~> 0.28", only: [:dev, :test]}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]
end
