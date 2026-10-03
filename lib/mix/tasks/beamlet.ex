defmodule Mix.Tasks.Beamlet do
  @shortdoc "Sets up the owner and manages tokens and policies on your beamlet"

  @moduledoc """
  Sets up the owner and manages tokens and policies on your beamlet.

  The development form of the `beamlet` command, run from the
  project:

      $ mix beamlet setup
      $ mix beamlet tokens.create laptop --policy explorer
      $ mix beamlet tokens
      $ mix beamlet policies
      $ mix beamlet reset
      $ mix beamlet --help

  The commands are `Beamlet.CLI`'s. This task loads the application
  config, hands the arguments over, and exits non-zero when a command
  fails. Nothing else starts, so it runs against the configured data
  dir whether a beamlet is running in another VM or not.
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
