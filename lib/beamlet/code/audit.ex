defmodule Beamlet.Code.Audit do
  @moduledoc false

  # The git history of the code dir. Files hold current state only;
  # git holds it over time. Beamlet is the sole committer, one commit
  # after each successful define, patch or remove, the subject naming the
  # modules and the trailers naming the principal, so `git log` in
  # the code dir reads as the record of everything built and torn
  # down. The agent has no git verbs and no knowledge git exists.
  #
  # Git trails the filesystem and never gatekeeps it: a hand-edited
  # file is swept into its own commit at the next boot under the
  # system principal, and a failed commit is logged and its changes
  # ride into the next `git add -A`. The repo carries no config of
  # its own; every commit names its author and committer as it is
  # made, and every commit carries trailers.

  require Logger

  alias Beamlet.Code.Source
  alias Beamlet.Principal

  @committer [{"GIT_COMMITTER_NAME", "beamlet"}, {"GIT_COMMITTER_EMAIL", "beamlet@beamlet"}]

  # A commit runs git's automatic maintenance, which git 2.47 and later
  # detach into the background by default, so it would still be
  # touching .git after the commit returns, racing a reset or a wipe.
  # gc.autoDetach is the same setting on older gits.
  @maintenance [
    {"GIT_CONFIG_COUNT", "2"},
    {"GIT_CONFIG_KEY_0", "maintenance.autoDetach"},
    {"GIT_CONFIG_VALUE_0", "false"},
    {"GIT_CONFIG_KEY_1", "gc.autoDetach"},
    {"GIT_CONFIG_VALUE_1", "false"}
  ]

  @doc """
  Raises with a teaching message when git is not on the `PATH`, so a
  beamlet without it fails at boot rather than at its first define.
  """
  @spec check!() :: :ok
  def check! do
    if System.find_executable("git") == nil do
      raise "git was not found on PATH. Beamlet keeps the history of defined modules " <>
              "in git; install git and start again."
    end

    :ok
  end

  @doc """
  Brings the code dir's history up to date at boot.

  A code dir with no repository gets one and an initial snapshot; one
  that has a repository gets its hand edits swept into a commit. Both
  are recorded under the system principal.
  """
  @spec after_boot(Path.t()) :: :ok
  def after_boot(code_dir) do
    if init_repo(code_dir),
      do: commit(code_dir, "initial snapshot", nil, Principal.system()),
      else: sweep(code_dir)
  end

  @doc """
  Commits a define, naming each module new or replaced in the subject.

  `diffs` holds the source diff of each replaced module, rendered into
  the body; the principal goes into the trailers.
  """
  @spec record_define(Path.t(), [module()], [module()], map(), Principal.t()) :: :ok
  def record_define(code_dir, modules, replaced, diffs, %Principal{} = principal) do
    subject =
      "define: " <>
        Enum.map_join(modules, ", ", fn mod ->
          flag = if mod in replaced, do: "replaced", else: "new"
          "#{inspect(mod)} (#{flag})"
        end)

    commit(code_dir, subject, diff_body(modules, diffs), principal)
  end

  @doc "Commits a patch, with each module's source diff in the body."
  @spec record_patch(Path.t(), [module()], map(), Principal.t()) :: :ok
  def record_patch(code_dir, modules, diffs, %Principal{} = principal) do
    subject = "patch: " <> Enum.map_join(modules, ", ", &inspect/1)
    commit(code_dir, subject, diff_body(modules, diffs), principal)
  end

  @doc "Commits the removal of modules."
  @spec record_remove(Path.t(), [module()], Principal.t()) :: :ok
  def record_remove(code_dir, modules, %Principal{} = principal) do
    commit(code_dir, "remove: " <> Enum.map_join(modules, ", ", &inspect/1), nil, principal)
  end

  defp init_repo(code_dir) do
    if File.dir?(Path.join(code_dir, ".git")) do
      false
    else
      git!(code_dir, ["init", "-q", "-b", "main", "--template="])
      File.write!(Path.join(code_dir, ".gitignore"), "/ebin/\n/.staging/\n")
      true
    end
  end

  # A hand edit is unusual enough to say so: the warning lists what
  # changed, and the commit it names is the point to roll back to.
  defp sweep(code_dir) do
    case git(code_dir, ["status", "--porcelain", "--untracked-files=all"]) do
      {"", 0} ->
        :ok

      {dirty, 0} ->
        Logger.warning(
          "code audit: manual changes in the code dir, committing them as \"manual changes\":\n" <>
            (dirty |> String.trim_trailing() |> String.replace(~r/^/m, "  "))
        )

        commit(code_dir, "manual changes", nil, Principal.system())

      {output, _status} ->
        log_failure("status", output)
    end
  end

  # The same function-level summary the tool result carries, so the
  # history says what a replace changed without a diff. A new module
  # has nothing to compare against and is left out.
  defp diff_body(modules, diffs) do
    case for(mod <- modules, Map.has_key?(diffs, mod), do: mod) do
      [] ->
        nil

      replaced ->
        Enum.map_join(replaced, "\n", fn mod ->
          Enum.join([inspect(mod) | Source.render_diff(Map.fetch!(diffs, mod))], "\n")
        end)
    end
  end

  # Empty commits are allowed so that a replace with the same source
  # is still on the record.
  defp commit(code_dir, subject, body, %Principal{} = principal) do
    paragraphs = [subject, body, Principal.to_trailers(principal)] |> Enum.reject(&is_nil/1)
    message = Enum.flat_map(paragraphs, &["-m", &1])
    args = ["-c", "commit.gpgsign=false", "commit", "-q", "--allow-empty" | message]

    with {_out, 0} <- git(code_dir, ["add", "-A"]),
         {_out, 0} <- git(code_dir, args, env: author(principal)) do
      :ok
    else
      {output, _status} -> log_failure("commit", output)
    end
  end

  defp author(%Principal{token_label: label}) do
    [{"GIT_AUTHOR_NAME", label}, {"GIT_AUTHOR_EMAIL", "#{label}@beamlet"}]
  end

  defp log_failure(step, output) do
    Logger.error("code audit: git #{step} failed, history not recorded: #{String.trim(output)}")
    :ok
  end

  # The ceiling stops git's upward repo discovery at the data dir: if
  # the code repo is ever missing, commands fail loudly instead of
  # landing in a repo the data dir happens to nest inside.
  defp git(code_dir, args, opts \\ []) do
    env =
      [{"GIT_CEILING_DIRECTORIES", Path.dirname(code_dir)} | @committer] ++
        @maintenance ++ Keyword.get(opts, :env, [])

    System.cmd("git", args, cd: code_dir, stderr_to_stdout: true, env: env)
  end

  defp git!(code_dir, args) do
    case git(code_dir, args) do
      {_out, 0} -> :ok
      {output, status} -> raise "git #{Enum.join(args, " ")} failed (#{status}): #{output}"
    end
  end
end
