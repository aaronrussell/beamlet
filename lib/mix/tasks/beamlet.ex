defmodule Mix.Tasks.Beamlet do
  @shortdoc "Sets up the owner and manages tokens and policies on your beamlet"

  @moduledoc """
  Runs the beamlet command line from Mix, in development.

      $ mix beamlet setup
      $ mix beamlet tokens.create laptop
      $ mix beamlet --help

  It works on the data dir your project's config names, whether or
  not the beamlet is running. It exits non-zero when a command fails,
  so it works in scripts.

  `Beamlet.CLI` describes each command. A release has no Mix, so the
  standalone server ships `bin/beamlet` instead, and your own release
  can call `Beamlet.CLI.main/1` from its `eval` command the same way.
  """

  use Mix.Task

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.config")
    restart_logger()

    case Beamlet.CLI.main(args) do
      :ok -> :ok
      :error -> exit({:shutdown, 1})
    end
  end

  # Mix starts the logger before it loads the project's config, and
  # only app.start restarts it under that config. Without this, every
  # query is logged at debug.
  defp restart_logger do
    Logger.App.stop()
    {:ok, _apps} = Application.ensure_all_started(:logger)
  end
end
