defmodule Beamlet.Code.Audit do
  @moduledoc false

  # The git history of the code dir. Files hold current state only;
  # git holds it over time. Beamlet is the sole committer, one commit
  # after each successful define or remove, the subject naming the
  # modules and the trailers naming the principal, so `git log` in
  # the code dir reads as the record of everything built and torn
  # down. The agent has no git verbs and no knowledge git exists.
  #
  # Git trails the filesystem and never gatekeeps it: a hand-edited
  # file is swept into its own commit at the next boot, and a failed
  # commit is logged and its changes ride into the next `git add -A`.
  # The repo carries no config of its own; every commit names its
  # author and committer as it is made.

  require Logger

  alias Beamlet.Principal

  @committer [{"GIT_COMMITTER_NAME", "beamlet"}, {"GIT_COMMITTER_EMAIL", "beamlet@beamlet"}]

  @spec check!() :: :ok
  def check! do
    if System.find_executable("git") == nil do
      raise "git was not found on PATH. Beamlet keeps the history of defined modules " <>
              "in git; install git and start again."
    end

    :ok
  end

  @spec after_boot(Path.t()) :: :ok
  def after_boot(code_dir) do
    if init_repo(code_dir), do: commit(code_dir, "initial snapshot", nil), else: sweep(code_dir)
  end

  @spec record_define(Path.t(), [module()], [module()], Principal.t()) :: :ok
  def record_define(code_dir, modules, replaced, %Principal{} = principal) do
    subject =
      "define: " <>
        Enum.map_join(modules, ", ", fn mod ->
          flag = if mod in replaced, do: "replaced", else: "new"
          "#{inspect(mod)} (#{flag})"
        end)

    commit(code_dir, subject, principal)
  end

  @spec record_remove(Path.t(), [module()], Principal.t()) :: :ok
  def record_remove(code_dir, modules, %Principal{} = principal) do
    commit(code_dir, "remove: " <> Enum.map_join(modules, ", ", &inspect/1), principal)
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

  defp sweep(code_dir) do
    case git(code_dir, ["status", "--porcelain"]) do
      {"", 0} -> :ok
      {_dirty, 0} -> commit(code_dir, "manual changes", nil)
      {output, _status} -> log_failure("status", output)
    end
  end

  # Empty commits are allowed so that a replace with the same source
  # is still on the record.
  defp commit(code_dir, subject, principal) do
    message =
      case principal do
        nil -> ["-m", subject]
        principal -> ["-m", subject, "-m", Principal.to_trailers(principal)]
      end

    args = ["-c", "commit.gpgsign=false", "commit", "-q", "--allow-empty" | message]

    with {_out, 0} <- git(code_dir, ["add", "-A"]),
         {_out, 0} <- git(code_dir, args, env: author(principal)) do
      :ok
    else
      {output, _status} -> log_failure("commit", output)
    end
  end

  defp author(nil), do: author("beamlet")
  defp author(%Principal{user_name: name}), do: author(name)

  defp author(name) when is_binary(name) do
    [{"GIT_AUTHOR_NAME", name}, {"GIT_AUTHOR_EMAIL", "#{name}@beamlet"}]
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
        Keyword.get(opts, :env, [])

    System.cmd("git", args, cd: code_dir, stderr_to_stdout: true, env: env)
  end

  defp git!(code_dir, args) do
    case git(code_dir, args) do
      {_out, 0} -> :ok
      {output, status} -> raise "git #{Enum.join(args, " ")} failed (#{status}): #{output}"
    end
  end
end
