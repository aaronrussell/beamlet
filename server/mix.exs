defmodule BeamletServer.MixProject do
  use Mix.Project

  def project do
    [
      app: :beamlet_server,
      version: "0.1.0",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      releases: releases()
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {BeamletServer.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:beamlet, path: ".."},
      {:phoenix, "~> 1.8"},
      {:phoenix_live_view, "~> 1.2"},
      {:jason, "~> 1.4"},
      {:bandit, "~> 1.5"}
    ]
  end

  # Agents read module docs through print_docs, and the policy tells
  # library internals from public surface by @moduledoc false, both
  # from the Docs chunk that a release strips by default.
  defp releases do
    [
      beamlet_server: [
        include_executables_for: [:unix],
        strip_beams: [keep: ["Docs"]]
      ]
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      precommit: ["compile --warnings-as-errors", "deps.unlock --unused", "format", "test"]
    ]
  end
end
