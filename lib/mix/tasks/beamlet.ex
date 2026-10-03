defmodule Mix.Tasks.Beamlet do
  @shortdoc "Sets up the owner and manages tokens and policies on your beamlet"

  @moduledoc """
  Runs the beamlet command line in development.

      $ mix beamlet setup
      $ mix beamlet tokens.create laptop

  It reads the project's config, runs one command and exits non-zero
  when the command fails. `Beamlet.CLI` describes each command.
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
