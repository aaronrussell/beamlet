defmodule Beamlet.MixProject do
  use Mix.Project

  @name "Beamlet"
  @description "An Elixir server that AI agents build from the inside, over MCP."
  @version "0.1.1"
  @source_url "https://github.com/aaronrussell/beamlet"

  def project do
    [
      app: :beamlet,
      name: @name,
      version: @version,
      elixir: "~> 1.19",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      docs: docs(),
      package: pkg()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test]
    ]
  end

  defp aliases do
    [
      "assets.build": ["tailwind app"],
      precommit: [
        "compile --warnings-as-errors",
        "deps.unlock --unused",
        "assets.build",
        "format",
        "test"
      ]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:anubis_mcp, "~> 2.0"},
      {:ecto_sql, "~> 3.14"},
      {:ecto_sqlite3, "~> 0.24"},
      {:ex_doc, "~> 0.40", only: :dev, runtime: false, warn_if_outdated: true},
      {:exqlite, "~> 0.41"},
      {:inet_cidr, "~> 1.0"},
      {:jason, "~> 1.4"},
      {:lazy_html, "~> 0.1", only: :test},
      {:makeup_json, ">= 0.0.0", only: :dev, runtime: false},
      {:pbkdf2_elixir, "~> 2.3"},
      {:phoenix, "~> 1.8"},
      {:phoenix_html, "~> 4.3"},
      {:phoenix_live_view, "~> 1.2"},
      {:phoenix_pubsub, "~> 2.1"},
      {:plug, "~> 1.20"},
      {:req, "~> 0.6"},
      {:req_ssrf, "~> 0.2"},
      {:tailwind, "~> 0.5", only: [:dev, :test], runtime: false}
    ]
  end

  defp pkg do
    [
      description: @description,
      licenses: ["Apache-2.0"],
      maintainers: ["Aaron Russell"],
      files: ~w(lib priv/repo priv/static .formatter.exs mix.exs CHANGELOG.md LICENSE README.md),
      links: %{
        "GitHub" => @source_url
      }
    ]
  end

  defp docs do
    [
      main: "getting-started",
      source_url: @source_url,
      source_ref: "v#{@version}",
      homepage_url: @source_url,
      extras: [
        "CHANGELOG.md",
        "guides/security.md",
        "guides/getting-started.md",
        "guides/working-with-your-beamlet.md",
        "guides/tokens-and-policies.md",
        "guides/operating-a-beamlet.md",
        "guides/deploy-beamlet-on-fly.md"
      ],
      assets: %{
        "guides/assets" => "assets"
      },
      groups_for_extras: [
        Guides: ~r/^guides\/(?!security)/
      ],
      skip_undefined_reference_warnings_on: ["CHANGELOG.md"],
      groups_for_modules: [
        MCP: ~r/^Beamlet.MCP\./,
        Web: [Beamlet.Router, Beamlet.Assets, ~r/^Beamlet.Web\./],
        "Host Stdlib": ~r/^Host\./
      ]
    ]
  end
end
