defmodule Host.FileTest do
  use Beamlet.Case, async: false

  describe "containment" do
    test "a relative escape raises the teaching error" do
      message = assert_raise(ArgumentError, fn -> Host.File.read("../outside.md") end).message
      assert message =~ "../outside.md escapes your beamlet's files"
      assert message =~ "`..` cannot leave it"
    end

    test "a nested escape raises" do
      assert_raise ArgumentError, ~r/escapes your beamlet's files/, fn ->
        Host.File.write("a/../../outside.md", "x")
      end
    end

    test "an absolute path is root-relative, not a real path" do
      assert Host.File.write("/notes.md", "hello") == :ok
      assert Host.File.read("notes.md") == {:ok, "hello"}
    end

    test "an absolute escape raises" do
      assert_raise ArgumentError, ~r/escapes your beamlet's files/, fn ->
        Host.File.read("/../outside.md")
      end
    end

    test "exists? raises on an escape rather than answering" do
      assert_raise ArgumentError, ~r/escapes your beamlet's files/, fn ->
        Host.File.exists?("../secret")
      end
    end

    test "a non-string path raises from tuple and bang alike" do
      assert_raise ArgumentError, "Host.File paths are strings, got: :notes", fn ->
        apply(Host.File, :read, [:notes])
      end

      assert_raise ArgumentError, "Host.File paths are strings, got: ~c\"notes\"", fn ->
        apply(Host.File, :read!, [~c"notes"])
      end
    end

    test "no error names the host's path", %{data_dir: data_dir} do
      escape = assert_raise(ArgumentError, fn -> Host.File.ls("../..") end).message
      missing = Exception.message(assert_raise(File.Error, fn -> Host.File.read!("nope.md") end))

      refute escape =~ data_dir
      refute missing =~ data_dir
    end
  end

  describe "files" do
    test "write creates parents and read round-trips" do
      assert Host.File.write("journal/2026/today.md", "entry") == :ok
      assert Host.File.read("journal/2026/today.md") == {:ok, "entry"}
    end

    test "write overwrites, and appends with the mode" do
      Host.File.write!("log.txt", "one\n")
      Host.File.write!("log.txt", "two\n")
      assert Host.File.read!("log.txt") == "two\n"

      Host.File.write!("log.txt", "three\n", [:append])
      assert Host.File.read!("log.txt") == "two\nthree\n"
    end

    test "read on a missing file is the posix error" do
      assert Host.File.read("nope.md") == {:error, :enoent}
    end

    test "rm removes a file and refuses a directory" do
      Host.File.write!("gone.md", "x")
      assert Host.File.rm("gone.md") == :ok
      refute Host.File.exists?("gone.md")

      Host.File.mkdir_p!("keep")
      assert Host.File.rm("keep") == {:error, :eisdir}
      assert Host.File.rm("nope.md") == {:error, :enoent}
    end

    test "cp copies a file into a new directory and leaves the source" do
      Host.File.write!("draft.md", "words")
      assert Host.File.cp("draft.md", "archive/2026/draft.md") == :ok
      assert Host.File.read!("archive/2026/draft.md") == "words"
      assert Host.File.read!("draft.md") == "words"
    end

    test "cp of a missing source is the posix error" do
      assert Host.File.cp("nope.md", "copy.md") == {:error, :enoent}
    end

    test "rename moves a file into a new directory" do
      Host.File.write!("draft.md", "words")
      assert Host.File.rename("draft.md", "posts/final.md") == :ok
      refute Host.File.exists?("draft.md")
      assert Host.File.read!("posts/final.md") == "words"
    end
  end

  describe "directories" do
    test "mkdir needs its parent and mkdir_p does not" do
      assert Host.File.mkdir("a/b") == {:error, :enoent}
      assert Host.File.mkdir_p("a/b/c") == :ok
      assert Host.File.mkdir("a/b/d") == :ok
      assert Host.File.dir?("a/b/c")
      assert Host.File.ls("a/b") == {:ok, ["c", "d"]}
    end

    test "rmdir removes an empty directory only" do
      Host.File.write!("full/file.md", "")
      assert Host.File.rmdir("full") in [{:error, :eexist}, {:error, :enotempty}]

      Host.File.mkdir_p!("empty")
      assert Host.File.rmdir("empty") == :ok
      refute Host.File.exists?("empty")
    end

    test "cp_r copies a tree and returns the root-relative paths copied" do
      Host.File.write!("src/a.md", "a")
      Host.File.write!("src/deep/b.md", "b")

      assert {:ok, copied} = Host.File.cp_r("src", "backup/src")

      assert Enum.sort(copied) == [
               "backup/src",
               "backup/src/a.md",
               "backup/src/deep",
               "backup/src/deep/b.md"
             ]

      assert Host.File.read!("backup/src/deep/b.md") == "b"
    end

    test "cp_r of a missing source names the root-relative path it failed on" do
      assert Host.File.cp_r("nope", "copy") == {:error, :enoent, "nope"}
    end

    test "rename moves a directory" do
      Host.File.write!("old/a.md", "a")
      assert Host.File.rename("old", "new/place") == :ok
      assert Host.File.read!("new/place/a.md") == "a"
      refute Host.File.exists?("old")
    end

    test "the predicates tell files, directories and absences apart" do
      refute Host.File.exists?("thing")
      Host.File.write!("thing/file.md", "")

      assert Host.File.exists?("thing")
      assert Host.File.dir?("thing")
      refute Host.File.regular?("thing")
      assert Host.File.regular?("thing/file.md")
      refute Host.File.dir?("thing/file.md")
    end
  end

  describe "listing" do
    test "a fresh filesystem lists as empty" do
      assert Host.File.ls() == {:ok, []}
      assert Host.File.ls_r() == {:ok, []}
    end

    test "ls is one level, names only, sorted" do
      Host.File.write!("b.md", "")
      Host.File.write!("journal/2026/today.md", "")
      Host.File.write!("a.md", "")

      assert Host.File.ls() == {:ok, ["a.md", "b.md", "journal"]}
      assert Host.File.ls("journal") == {:ok, ["2026"]}
      assert Host.File.ls("nope") == {:error, :enoent}
    end

    test "ls_r returns every file as sorted root-relative paths" do
      Host.File.write!("b.md", "")
      Host.File.write!("journal/2026/today.md", "")
      Host.File.write!("a.md", "")
      Host.File.mkdir_p!("empty")

      assert Host.File.ls_r() == {:ok, ["a.md", "b.md", "journal/2026/today.md"]}
      assert Host.File.ls_r("journal") == {:ok, ["journal/2026/today.md"]}
      assert Host.File.ls_r("/journal/") == {:ok, ["journal/2026/today.md"]}
    end

    test "ls_r on a file is the posix error" do
      Host.File.write!("flat.md", "")
      assert Host.File.ls_r("flat.md") == {:error, :enotdir}
    end
  end

  describe "bangs" do
    test "raise File.Error with the path as written and File's message" do
      error = assert_raise(File.Error, fn -> Host.File.read!("/nope.md") end)

      assert error.path == "/nope.md"
      assert error.reason == :enoent

      assert Exception.message(error) ==
               ~s|could not read file "/nope.md": no such file or directory|
    end

    test "rm! on a directory reads as an illegal operation" do
      Host.File.mkdir_p!("keep")

      assert_raise File.Error,
                   ~s|could not remove file "keep": illegal operation on a directory|,
                   fn ->
                     Host.File.rm!("keep")
                   end
    end

    test "cp! and cp_r! raise File.CopyError" do
      assert_raise File.CopyError,
                   ~s|could not copy from "nope.md" to "x.md": no such file or directory|,
                   fn ->
                     Host.File.cp!("nope.md", "x.md")
                   end

      error = assert_raise(File.CopyError, fn -> Host.File.cp_r!("nope", "x") end)
      assert error.on == "nope"
      assert Exception.message(error) =~ ~s|could not copy recursively from "nope" to "x"|
    end

    test "rename! raises File.RenameError" do
      error = assert_raise(File.RenameError, fn -> Host.File.rename!("nope.md", "x.md") end)
      assert error.reason == :enoent
      assert Exception.message(error) =~ ~s|could not rename from "nope.md" to "x.md"|
    end

    test "every bang returns the value on success" do
      assert Host.File.mkdir_p!("a/b") == :ok
      assert Host.File.mkdir!("a/c") == :ok
      assert Host.File.write!("a/b/one.md", "1") == :ok
      assert Host.File.read!("a/b/one.md") == "1"
      assert Host.File.ls!("a") == ["b", "c"]
      assert Host.File.ls_r!("a") == ["a/b/one.md"]
      assert Host.File.cp!("a/b/one.md", "a/b/two.md") == :ok
      assert Host.File.cp_r!("a/b", "d") == ["d", "d/one.md", "d/two.md"]
      assert Host.File.rename!("d", "e") == :ok
      assert Host.File.rm!("e/one.md") == :ok
      assert Host.File.rm!("e/two.md") == :ok
      assert Host.File.rmdir!("e") == :ok
    end
  end

  describe "the shared root" do
    test "lives under the data dir and exists after boot", %{data_dir: data_dir} do
      assert File.dir?(Path.join(data_dir, "files"))
      Host.File.write!("notes.md", "here")
      assert File.read!(Path.join(data_dir, "files/notes.md")) == "here"
    end

    test "resolution is stateless: every process sees the same files" do
      Host.File.write!("notes.md", "from the test process")

      Task.async(fn ->
        assert Host.File.read!("notes.md") == "from the test process"
        Host.File.write!("notes.md", "from another process")
      end)
      |> Task.await()

      assert Host.File.read!("notes.md") == "from another process"
    end
  end
end
