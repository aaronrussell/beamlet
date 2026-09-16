defmodule Host.File do
  @moduledoc """
  `File`, scoped to your beamlet's files.

  Paths are relative to the files root, and a leading `/` means that
  same root: `"notes.md"` and `"/notes.md"` are the same file, and
  `..` cannot leave it. Names, arguments and results mirror `File`'s.
  A function returns `:ok`, `{:ok, value}` or `{:error, reason}` with
  a posix reason such as `:enoent`; its bang variant returns the
  value or raises what `File`'s does, naming the path as you wrote
  it. Code written for `File` works here. The one addition: writing,
  copying and renaming create the parent directories they need.

      Host.File.write!("journal/2026/today.md", "entry")
      Host.File.read!("journal/2026/today.md")
      #=> "entry"

      case Host.File.read("settings.json") do
        {:ok, json} -> JSON.decode!(json)
        {:error, :enoent} -> %{}
      end

  There is one filesystem for the whole beamlet: every user, every
  defined module and every process sees the same files, including
  code serving web routes, so organise shared work with directories.
  Files persist across evals and restarts. Nothing here runs as
  anyone, so it works the same from an eval, a controller or a
  LiveView. `ls_r/1` shows everything there is.
  """

  alias Beamlet.Config

  @doc """
  Returns the contents of the file at `path`, e.g.
  `read("notes.md")`.
  """
  @spec read(String.t()) :: {:ok, binary()} | {:error, File.posix()}
  def read(path), do: File.read(resolve!(path))

  @doc "Like `read/1`, returning the contents or raising `File.Error`."
  @spec read!(String.t()) :: binary()
  def read!(path), do: unwrap!("read file", path, read(path))

  @doc """
  Writes `content` to the file at `path`, creating parent directories
  as needed and overwriting an existing file, e.g.
  `write("journal/today.md", text)`. Pass `[:append]` to add to the
  end instead.
  """
  @spec write(String.t(), iodata(), [File.mode()]) :: :ok | {:error, File.posix()}
  def write(path, content, modes \\ []) do
    full = resolve!(path)

    with :ok <- File.mkdir_p(Path.dirname(full)), do: File.write(full, content, modes)
  end

  @doc "Like `write/3`, returning `:ok` or raising `File.Error`."
  @spec write!(String.t(), iodata(), [File.mode()]) :: :ok
  def write!(path, content, modes \\ []) do
    unwrap!("write to file", path, write(path, content, modes))
  end

  @doc """
  Returns the names in the directory at `path`, sorted, e.g.
  `ls("journal")`. The root when `path` is omitted. Files and
  directories alike, names only; for every file beneath a directory
  use `ls_r/1`.
  """
  @spec ls(String.t()) :: {:ok, [String.t()]} | {:error, File.posix()}
  def ls(path \\ "/") do
    with {:ok, names} <- File.ls(resolve!(path)), do: {:ok, Enum.sort(names)}
  end

  @doc "Like `ls/1`, returning the names or raising `File.Error`."
  @spec ls!(String.t()) :: [String.t()]
  def ls!(path \\ "/"), do: unwrap!("list directory", path, ls(path))

  @doc """
  Returns every file under the directory at `path`, sorted, as paths
  relative to the root, ready to pass to `read/1`. The whole
  filesystem when `path` is omitted.

  Directories appear through the files they contain; an empty
  directory is not listed. A fresh filesystem lists as `{:ok, []}`.
  """
  @spec ls_r(String.t()) :: {:ok, [String.t()]} | {:error, File.posix()}
  def ls_r(path \\ "/") do
    with {:ok, files} <- files_under(resolve!(path)) do
      {:ok, files |> Enum.map(&relative/1) |> Enum.sort()}
    end
  end

  @doc "Like `ls_r/1`, returning the paths or raising `File.Error`."
  @spec ls_r!(String.t()) :: [String.t()]
  def ls_r!(path \\ "/"), do: unwrap!("list directory recursively", path, ls_r(path))

  @doc """
  Creates the directory at `path`; its parent must exist. Writing a
  file creates its parents on its own, so this is for a directory
  wanted ahead of any file. See `mkdir_p/1` for missing parents.
  """
  @spec mkdir(String.t()) :: :ok | {:error, File.posix()}
  def mkdir(path), do: File.mkdir(resolve!(path))

  @doc "Like `mkdir/1`, returning `:ok` or raising `File.Error`."
  @spec mkdir!(String.t()) :: :ok
  def mkdir!(path), do: unwrap!("make directory", path, mkdir(path))

  @doc "Creates the directory at `path`, including missing parents, e.g. `mkdir_p(\"a/b/c\")`."
  @spec mkdir_p(String.t()) :: :ok | {:error, File.posix()}
  def mkdir_p(path), do: File.mkdir_p(resolve!(path))

  @doc "Like `mkdir_p/1`, returning `:ok` or raising `File.Error`."
  @spec mkdir_p!(String.t()) :: :ok
  def mkdir_p!(path), do: unwrap!("make directory (with -p)", path, mkdir_p(path))

  @doc """
  Removes the file at `path`. Files only: a directory answers
  `{:error, :eisdir}`. Use `rmdir/1` for an empty directory.
  """
  @spec rm(String.t()) :: :ok | {:error, File.posix()}
  def rm(path) do
    full = resolve!(path)

    if File.dir?(full), do: {:error, :eisdir}, else: File.rm(full)
  end

  @doc "Like `rm/1`, returning `:ok` or raising `File.Error`."
  @spec rm!(String.t()) :: :ok
  def rm!(path), do: unwrap!("remove file", path, rm(path))

  @doc "Removes the empty directory at `path`."
  @spec rmdir(String.t()) :: :ok | {:error, File.posix()}
  def rmdir(path), do: File.rmdir(resolve!(path))

  @doc "Like `rmdir/1`, returning `:ok` or raising `File.Error`."
  @spec rmdir!(String.t()) :: :ok
  def rmdir!(path), do: unwrap!("remove directory", path, rmdir(path))

  @doc """
  Copies the file at `source` to `dest`, creating parent directories
  as needed, e.g. `cp("draft.md", "archive/draft.md")`. Files only;
  see `cp_r/2` for a directory.
  """
  @spec cp(String.t(), String.t()) :: :ok | {:error, File.posix()}
  def cp(source, dest) do
    src = resolve!(source)
    dst = resolve!(dest)

    with :ok <- File.mkdir_p(Path.dirname(dst)), do: File.cp(src, dst)
  end

  @doc "Like `cp/2`, returning `:ok` or raising `File.CopyError`."
  @spec cp!(String.t(), String.t()) :: :ok
  def cp!(source, dest) do
    case cp(source, dest) do
      :ok -> :ok
      {:error, reason} -> copy_error!("copy", source, dest, "", reason)
    end
  end

  @doc """
  Copies `source` to `dest` recursively, creating parent directories
  as needed, e.g. `cp_r("notes", "backup/notes")`. Returns the paths
  copied, relative to the root, or the error with the path it
  happened on.
  """
  @spec cp_r(String.t(), String.t()) ::
          {:ok, [String.t()]} | {:error, File.posix(), String.t()}
  def cp_r(source, dest) do
    src = resolve!(source)
    dst = resolve!(dest)
    parent = Path.dirname(dst)

    with :ok <- File.mkdir_p(parent) |> on(parent),
         {:ok, copied} <- File.cp_r(src, dst) do
      {:ok, copied |> Enum.map(&relative/1) |> Enum.sort()}
    else
      {:error, reason, file} -> {:error, reason, relative(file)}
    end
  end

  @doc "Like `cp_r/2`, returning the paths copied or raising `File.CopyError`."
  @spec cp_r!(String.t(), String.t()) :: [String.t()]
  def cp_r!(source, dest) do
    case cp_r(source, dest) do
      {:ok, copied} -> copied
      {:error, reason, file} -> copy_error!("copy recursively", source, dest, file, reason)
    end
  end

  @doc """
  Renames or moves `source` to `dest`, file or directory, creating
  parent directories as needed, e.g.
  `rename("draft.md", "posts/final.md")`.
  """
  @spec rename(String.t(), String.t()) :: :ok | {:error, File.posix()}
  def rename(source, dest) do
    src = resolve!(source)
    dst = resolve!(dest)

    with :ok <- File.mkdir_p(Path.dirname(dst)), do: File.rename(src, dst)
  end

  @doc "Like `rename/2`, returning `:ok` or raising `File.RenameError`."
  @spec rename!(String.t(), String.t()) :: :ok
  def rename!(source, dest) do
    case rename(source, dest) do
      :ok ->
        :ok

      {:error, reason} ->
        raise File.RenameError,
          action: "rename",
          source: source,
          destination: dest,
          on: "",
          reason: reason
    end
  end

  @doc "Whether a file or directory exists at `path`."
  @spec exists?(String.t()) :: boolean()
  def exists?(path), do: File.exists?(resolve!(path))

  @doc "Whether `path` is a directory."
  @spec dir?(String.t()) :: boolean()
  def dir?(path), do: File.dir?(resolve!(path))

  @doc "Whether `path` is a regular file."
  @spec regular?(String.t()) :: boolean()
  def regular?(path), do: File.regular?(resolve!(path))

  defp files_under(dir) do
    with {:ok, entries} <- File.ls(dir) do
      Enum.reduce_while(entries, {:ok, []}, fn entry, {:ok, found} ->
        full = Path.join(dir, entry)

        case entry_files(full) do
          {:ok, files} -> {:cont, {:ok, files ++ found}}
          error -> {:halt, error}
        end
      end)
    end
  end

  defp entry_files(full), do: if(File.dir?(full), do: files_under(full), else: {:ok, [full]})

  defp on(:ok, _path), do: :ok
  defp on({:error, reason}, path), do: {:error, reason, path}

  defp unwrap!(_action, _path, :ok), do: :ok
  defp unwrap!(_action, _path, {:ok, value}), do: value

  defp unwrap!(action, path, {:error, reason}) do
    raise File.Error, action: action, path: path, reason: reason
  end

  defp copy_error!(action, source, dest, on, reason) do
    raise File.CopyError,
      action: action,
      source: source,
      destination: dest,
      on: on,
      reason: reason
  end

  # Containment: a leading "/" means the files root (Path.expand/2
  # ignores the base for an absolute path, so it is stripped before
  # the join), and the expanded result must stay under the root.
  # Escapes and non-strings raise from every function, tuple or bang:
  # they are misuse of the API, not a condition to handle.
  defp resolve!(path) when is_binary(path) do
    root = root()
    full = Path.expand(String.trim_leading(path, "/"), root)

    if full == root or String.starts_with?(full, root <> "/") do
      full
    else
      raise ArgumentError,
            "#{path} escapes your beamlet's files: Host.File paths resolve inside " <>
              "the files root, and `..` cannot leave it"
    end
  end

  defp resolve!(path) do
    raise ArgumentError, "Host.File paths are strings, got: #{inspect(path)}"
  end

  defp relative(full), do: Path.relative_to(full, root())

  defp root, do: Path.expand(Config.files_dir())
end
