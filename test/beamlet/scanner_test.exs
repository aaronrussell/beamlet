defmodule Beamlet.ScannerTest do
  use ExUnit.Case, async: true

  alias Beamlet.Policy
  alias Beamlet.Scanner
  alias Beamlet.TestPolicies

  @default Policy.default()
  @doors_open TestPolicies.doors_open()

  defp policy(document), do: Policy.build(:x, document) |> then(fn {:ok, p} -> p end)

  defp scan(code, policy \\ @default), do: Scanner.scan_eval(code, policy)

  defp scan_error(code, policy \\ @default) do
    assert {:error, message} = scan(code, policy)
    message
  end

  defp scan_define(code, policy \\ @default), do: Scanner.scan_define(code, policy)

  defp scan_define_error(code, policy \\ @default) do
    assert {:error, message} = scan_define(code, policy)
    message
  end

  describe "allowed code" do
    test "core data pipelines pass" do
      assert :ok =
               scan("""
               [1, 2, 3]
               |> Enum.map(&(&1 * 2))
               |> Enum.sum()
               """)
    end

    test "string interpolation and sigils pass" do
      assert :ok = scan(~S|name = "world"; IO.puts("hello #{name}")|)
      assert :ok = scan("~r/foo/ |> Regex.match?(\"foo\")")
    end

    test "comprehensions, fn, and access sugar pass" do
      assert :ok = scan("for x <- [1, 2], x > 1, do: x * 2")
      assert :ok = scan("f = fn x -> x + 1 end; f.(1)")
      assert :ok = scan("m = %{a: 1}; m[:a]")
    end

    test "no-parens dot on a variable reads as map access and passes" do
      assert :ok = scan("m = %{a: 1}; m.a")
    end

    test "allowed captures and structs pass" do
      assert :ok = scan("Enum.map([1], &Integer.to_string/1)")
      assert :ok = scan("%URI{host: \"example.com\"}")
    end

    test "aliases expand before the policy check" do
      assert :ok = scan("alias Enum, as: E\nE.sum([1, 2])")
    end

    test "an as: alias cannot launder a denied module" do
      assert scan_error("alias File, as: Storage\nStorage.read!(\"x\")") =~
               "File.read!/1 — File is not permitted"
    end

    test "multi-aliases expand to their full names" do
      assert scan_error("alias Foo.{Bar, Baz}\nBar.go()") =~
               "Foo.Bar.go/0 — nothing named Foo.Bar exists on your beamlet"
    end

    test "imports of granted modules pass" do
      assert :ok = scan("import Enum\nsum([1, 2])")
      assert :ok = scan("import IO, only: [puts: 1]\nputs(\"hi\")")
    end

    test "use of a granted module passes" do
      assert :ok = scan("use Bitwise\n1 &&& 2")
    end

    test "unknown locals pass through to eval" do
      assert :ok = scan("frobnicate(1)")
    end

    test "a policy's own grant is honoured" do
      assert :ok = scan("File.read!(\"/tmp/x\")", policy(allow: [{File, only: [read!: 1]}]))
    end
  end

  describe "policy violations" do
    test "a denied module names itself" do
      message = scan_error("x = 1\nFile.read!(\"/etc/passwd\")")
      assert message =~ "line 2: File.read!/1 — File is not permitted by your policy"
    end

    test "a denied function of a granted module names the function" do
      assert scan_error("IO.gets(\"? \")") =~ "IO.gets/1 is not permitted by your policy"
    end

    test "erlang modules are policy-checked" do
      assert scan_error(":os.cmd(~c\"whoami\")") =~ ":os.cmd/1 — :os is not permitted"
    end

    test "the concurrency family carries its closure" do
      assert scan_error("Process.sleep(1000)") =~ "process primitives are withheld as a family"
      assert scan_error("Task.async(fn -> 1 end)") =~ "process primitives"
    end

    test "the laundering functions are plain denials" do
      assert scan_error("String.to_atom(\"x\")") =~
               ~r/String\.to_atom\/1 is not permitted by your policy$/

      assert scan_error("apply(Enum, :sum, [[1]])") =~
               ~r/apply\/3 is not permitted by your policy$/
    end

    test "the Kernel entry is the local-call blacklist" do
      assert scan_error("spawn(fn -> 1 end)") =~
               "spawn/1 is not permitted by your policy — process primitives"

      assert scan_error("send(self(), :hi)") =~ "send/2 is not permitted"
      assert scan_error("apply(Enum, :sum, [[1]])") =~ "apply/3 is not permitted"
    end

    test "pipes are checked at their effective arity" do
      assert :ok = scan("\"/tmp/x\" |> File.read!()", policy(allow: [{File, only: [read!: 1]}]))
      assert scan_error("\"a\" |> String.to_atom()") =~ "String.to_atom/1"
    end

    test "captures are checked at the captured arity" do
      assert scan_error("Enum.map([\"a\"], &String.to_atom/1)") =~ "String.to_atom/1"
    end

    test "structs of denied modules are rejected" do
      assert scan_error("%File{}") =~ "File is not permitted"
    end

    test "a module that does not exist teaches define, not policy" do
      message = scan_error("Meal.Plan.plan_item(\"pasta\", 2)")
      assert message =~ "nothing named Meal.Plan exists on your beamlet"
      assert message =~ "check the name, or define it first"
      refute message =~ "not permitted"
    end

    test "require of a denied module is rejected" do
      assert scan_error("require Logger") =~ "Logger is not permitted"
    end

    test "all violations are collected and sorted by line" do
      message =
        scan_error("""
        File.read!("/tmp/a")
        x = 1
        :os.cmd(~c"whoami")
        """)

      assert [first, second] = String.split(message, "\n")
      assert first =~ "line 1: File.read!/1"
      assert second =~ "line 3: :os.cmd/1"
    end
  end

  describe "signage" do
    test "a redirect fires once the policy grants its door" do
      {:ok, closed} = Policy.build(:closed, deny: [Host.File])
      assert scan_error("File.read!(\"x\")", closed) =~ ~r/File is not permitted by your policy$/

      assert scan_error("File.read!(\"x\")") =~
               "File is not permitted by your policy — Host.File provides scoped file access"
    end

    test "a redirect is dropped when the policy denies its door" do
      assert scan_error("Ecto.Repo.all(Beamlet.Repo)") =~
               "Ecto.Repo is not permitted by your policy — " <>
                 "the agent database is reached through Host.Repo"

      assert scan_error("Ecto.Repo.all(Beamlet.Repo)", policy(deny: [Host.Repo])) =~
               ~r/Ecto\.Repo is not permitted by your policy$/
    end

    test "the define redirect is dropped for an eval-only policy" do
      assert scan_error("Code.eval_string(\"1\")") =~ "durable code is made with the define tool"

      assert scan_error("Code.eval_string(\"1\")", policy(tools: [:eval])) =~
               ~r/Code is not permitted by your policy$/
    end

    test "Phoenix.PubSub and Ecto.Migrator carry their stdlib redirects" do
      assert scan_error(~s|Phoenix.PubSub.broadcast(Beamlet.PubSub, "t", :m)|, @doors_open) =~
               "publish/subscribe goes through Host.PubSub"

      assert scan_error(~s|Ecto.Migrator.run(Host.Repo, :up, all: true)|, @doors_open) =~
               "migrations are run through Host.Migrator"
    end
  end

  describe "imports" do
    test "a bare import of a denied module is rejected" do
      assert scan_error("import File") =~ "import File — File is not permitted"
    end

    test "a bare import of a restricted module teaches the explicit form" do
      message = scan_error("import IO")
      assert message =~ "import IO must list allowed functions explicitly"
      assert message =~ "only partially permitted by your policy"
    end

    test "an only: list is subset-validated" do
      assert scan_error("import IO, only: [gets: 1]") =~ "IO.gets/1 is not permitted"
    end

    test "a malformed only: list teaches the shape" do
      assert scan_error("import Enum, only: [:map]") =~ "`function: arity` pairs"
    end
  end

  describe "structural rules" do
    test "a variable call target is rejected" do
      message = scan_error("mod = Enum\nmod.sum([1])")
      assert message =~ "line 2: call target must be a literal module"
      assert message =~ "`mod.sum(...)` with a variable is not allowed"
    end

    test "a variable capture target is rejected" do
      assert scan_error("mod = Enum\nEnum.map([[1]], &mod.sum/1)") =~
               "capture target must be a literal module, got: &mod.sum/1"
    end

    test "module definitions are rejected" do
      assert scan_error("defmodule Foo do\nend") =~
               "eval evaluates expressions — module definitions are not permitted"

      assert scan_error("Kernel.defmodule Foo do\nend") =~ "module definitions are not permitted"
      assert scan_error("defimpl String.Chars, for: Tuple do\nend") =~ "module definitions"
    end

    test "an unpipeable pipe is rejected" do
      assert scan_error("x = 1\n1 |> 5") =~ "cannot pipe into 5"
    end
  end

  describe "parse errors" do
    test "carry the line" do
      assert scan_error("Enum.map([1,") =~ ~r/^line 1: /
    end
  end

  describe "scan_define/2 structure" do
    test "a documented module returns its name" do
      assert {:ok, [Scan.Fixture.One]} =
               scan_define("""
               defmodule Scan.Fixture.One do
                 @moduledoc "A fixture."

                 @doc "Doubles."
                 def double(x), do: x * 2
               end
               """)
    end

    test "a multi-module buffer returns every name and allows cross-references" do
      assert {:ok, [Scan.Fixture.A, Scan.Fixture.B]} =
               scan_define("""
               defmodule Scan.Fixture.A do
                 @moduledoc "A."
                 @doc "One."
                 def one, do: 1
               end

               defmodule Scan.Fixture.B do
                 @moduledoc "B."
                 @doc "Two."
                 def two, do: Scan.Fixture.A.one() + 1
               end
               """)
    end

    test "a top-level expression is rejected" do
      message =
        scan_define_error("""
        defmodule Scan.Fixture.C do
          @moduledoc "C."
        end

        IO.puts("hello")
        """)

      assert message =~ "line 5: define declares modules — run expressions with eval"
    end

    test "a nested defmodule names the full module" do
      message =
        scan_define_error("""
        defmodule Outer do
          @moduledoc "Outer."

          defmodule Inner do
            @moduledoc "Inner."
          end
        end
        """)

      assert message =~ "define Outer.Inner as its own top-level defmodule"
      assert message =~ "nested module definitions are not permitted"
    end

    test "protocols are rejected" do
      assert scan_define_error("defprotocol Scan.Fixture.P do\nend") =~
               "defprotocol and defimpl are not supported — define a plain module"

      assert scan_define_error("defimpl String.Chars, for: Tuple do\nend") =~
               "defprotocol and defimpl are not supported"
    end

    test "a duplicate module name is rejected" do
      message =
        scan_define_error("""
        defmodule Scan.Fixture.D do
          @moduledoc "D."
        end

        defmodule Scan.Fixture.D do
          @moduledoc "D again."
        end
        """)

      assert message =~ "Scan.Fixture.D is defined more than once in this buffer"
    end

    test "a non-literal module name is rejected" do
      assert scan_define_error("defmodule unquote(name) do\nend") =~
               "module name must be a literal, like Shopping.List"
    end

    test "a defmodule without a body is rejected" do
      assert scan_define_error("defmodule Scan.Fixture.E") =~ "missing its do ... end body"
    end
  end

  describe "scan_define/2 policy" do
    test "a policy violation inside a body is reported with its line" do
      message =
        scan_define_error("""
        defmodule Scan.Fixture.F do
          @moduledoc "F."

          @doc "Reads."
          def read(path), do: File.read!(path)
        end
        """)

      assert message =~ "line 5: File.read!/1 — File is not permitted"
    end

    test "use of a denied module is rejected" do
      assert scan_define_error("""
             defmodule Scan.Fixture.G do
               @moduledoc "G."
               use GenServer
             end
             """) =~ "use GenServer — GenServer is not permitted"
    end

    test "the LiveView authoring shape passes the scan" do
      assert {:ok, _modules} =
               scan_define("""
               defmodule Scan.Fixture.PageLive do
                 @moduledoc "A page."
                 use Phoenix.LiveView

                 @doc false
                 def mount(_params, _session, socket) do
                   {:ok, Phoenix.Component.assign(socket, count: 1)}
                 end

                 @doc false
                 def render(assigns) do
                   ~H"<div>{@count}</div>"
                 end
               end
               """)
    end

    @tag skip: "Host.Web lands at step 15"
    test "the Host.Web authoring shape passes the scan" do
      assert {:ok, _modules} =
               scan_define("""
               defmodule Scan.Fixture.WebLive do
                 @moduledoc "A page."
                 use Host.Web, :live_view

                 @doc false
                 def mount(_params, _session, socket) do
                   {:ok, assign(socket, next: ~p"/notes")}
                 end

                 @doc false
                 def render(assigns) do
                   ~H"<div>{@next}</div>"
                 end
               end
               """)
    end

    test "denied web machinery carries the routing redirect" do
      code = """
      defmodule Scan.Fixture.R do
        @moduledoc "R."
        use Phoenix.Router
      end
      """

      assert scan_define_error(code) =~ ~r/Phoenix\.Router is not permitted by your policy$/

      assert scan_define_error(code, @doors_open) =~
               "the URL surface is managed through Host.Router"
    end

    test "the send_file carve-out carries the fs redirect" do
      assert scan_define_error(
               """
               defmodule Scan.Fixture.S do
                 @moduledoc "S."

                 @doc "Serves."
                 def serve(conn, path), do: Plug.Conn.send_file(conn, 200, path)
               end
               """,
               @doors_open
             ) =~ "Plug.Conn.send_file/3 is not permitted by your policy — Host.File provides"
    end

    test "a buffer-local function may shadow a denied Kernel import" do
      assert {:ok, _modules} =
               scan_define("""
               defmodule Scan.Fixture.H do
                 @moduledoc "H."

                 @doc "Not Kernel.send/2."
                 def send(target, message), do: {target, message}

                 @doc "Calls the local."
                 def go, do: send(:a, :b)
               end
               """)
    end

    test "locals with default arguments are known at every arity" do
      assert {:ok, _modules} =
               scan_define("""
               defmodule Scan.Fixture.I do
                 @moduledoc "I."

                 @doc "Greets."
                 def greet(name, greeting \\\\ "hello"), do: "\#{greeting} \#{name}"

                 @doc "Uses the default."
                 def hi, do: greet("world")
               end
               """)
    end

    test "module attributes and specs do not false-positive" do
      assert {:ok, _modules} =
               scan_define("""
               defmodule Scan.Fixture.J do
                 @moduledoc "J."
                 @enforce_keys [:name]
                 defstruct [:name, :count]

                 @doc "Builds."
                 @spec build(String.t()) :: %__MODULE__{}
                 def build(name) when is_binary(name), do: %__MODULE__{name: name}
               end
               """)
    end
  end

  describe "scan_define/2 data-position targets" do
    test "defdelegate to a denied module is rejected at the delegated name/arity" do
      message =
        scan_define_error(
          """
          defmodule Scan.Fixture.K do
            @moduledoc "K."
            @doc "Removes."
            defdelegate rm(path), to: File
          end
          """,
          @doors_open
        )

      assert message =~ "line 4: File.rm/1 — File is not permitted"
      assert message =~ "Host.File provides scoped file access"
    end

    test "defdelegate honors as: when resolving the target function" do
      assert scan_define_error("""
             defmodule Scan.Fixture.L do
               @moduledoc "L."
               @doc "Atomizes."
               defdelegate atomize(s), to: String, as: :to_atom
             end
             """) =~ "String.to_atom/1 is not permitted"
    end

    test "defdelegate checks every head of the list form" do
      message =
        scan_define_error("""
        defmodule Scan.Fixture.M do
          @moduledoc "M."
          defdelegate [rm_rf(path), mkdir(path)], to: File
        end
        """)

      assert message =~ "File.rm_rf/1 — File is not permitted"
      assert message =~ "File.mkdir/1 — File is not permitted"
    end

    test "defdelegate to a granted module passes" do
      assert {:ok, _modules} =
               scan_define("""
               defmodule Scan.Fixture.N do
                 @moduledoc "N."
                 @doc "Upcases."
                 defdelegate up(s), to: String, as: :upcase
               end
               """)
    end

    test "defdelegate to a non-literal target is rejected" do
      assert scan_define_error("""
             defmodule Scan.Fixture.O do
               @moduledoc "O."
               @target File
               defdelegate rm(path), to: @target
             end
             """) =~ "defdelegate to: must be a literal module"
    end

    test "compile-hook attributes naming a denied module are rejected" do
      message =
        scan_define_error("""
        defmodule Scan.Fixture.P2 do
          @moduledoc "P2."
          @before_compile File
          @on_definition File
        end
        """)

      assert message =~ "line 3: @before_compile File — File is not permitted"
      assert message =~ "line 4: @on_definition File — File is not permitted"
    end

    test "a hook tuple checks the named function at the hook's arity" do
      assert scan_define_error("""
             defmodule Scan.Fixture.Q do
               @moduledoc "Q."
               @after_compile {IO, :write}
             end
             """) =~ "IO.write/2 is not permitted"
    end

    test "a non-literal hook target is rejected" do
      assert scan_define_error("""
             defmodule Scan.Fixture.R do
               @moduledoc "R."
               @mod File
               @before_compile @mod
             end
             """) =~ "@before_compile target must be a literal module"
    end

    test "@derive checks every entry, tuple options included" do
      message =
        scan_define_error("""
        defmodule Scan.Fixture.S do
          @moduledoc "S."
          @derive [Inspect, {File, only: [:a]}]
          defstruct [:a]
        end
        """)

      assert message =~ "@derive File — File is not permitted"
      refute message =~ "Inspect"
    end

    test "@derive of granted protocols passes" do
      assert {:ok, _modules} =
               scan_define("""
               defmodule Scan.Fixture.T do
                 @moduledoc "T."
                 @derive [Inspect, {JSON.Encoder, only: [:a]}]
                 defstruct [:a]
               end
               """)
    end

    test "@behaviour is deliberately unchecked: it names a module but executes nothing" do
      assert {:ok, _modules} =
               scan_define("""
               defmodule Scan.Fixture.U do
                 @moduledoc "U."
                 @behaviour GenServer
               end
               """)
    end

    test "__MODULE__ is an allowed module everywhere a target is expected" do
      assert {:ok, _modules} =
               scan_define("""
               defmodule Scan.Fixture.V do
                 @moduledoc "V."
                 @before_compile __MODULE__
                 @after_compile {__MODULE__, :check}

                 @doc "Compile hook."
                 def check(_env, _bytecode), do: :ok

                 @doc "Helps."
                 def helper(x), do: x

                 @doc "Calls itself the long way."
                 def run, do: Enum.map([1], &__MODULE__.helper/1) ++ [__MODULE__.helper(2)]
               end
               """)
    end

    test "defguard declarations and uses pass the scan" do
      assert {:ok, _modules} =
               scan_define("""
               defmodule Scan.Fixture.W do
                 @moduledoc "W."

                 @doc "True for adults."
                 defguard is_adult(age) when is_integer(age) and age >= 18
                 defguardp is_teen(age) when is_integer(age) and age in 13..19

                 @doc "Checks."
                 def check(age) when is_adult(age), do: :adult
                 def check(age) when is_teen(age), do: :teen
               end
               """)
    end
  end

  describe "the defmacro rule" do
    @macro_module """
    defmodule Scan.Fixture.M do
      @moduledoc "M."

      @doc "Doubles at compile time."
      defmacro double(x) do
        quote do: unquote(x) * 2
      end
    end
    """

    test "defmacro is rejected under strict rules" do
      assert scan_define_error(@macro_module) =~ "defmacro is not permitted by your policy"
    end

    test "defmacrop is rejected under strict rules, naming itself" do
      assert scan_define_error("""
             defmodule Scan.Fixture.MP do
               @moduledoc "MP."

               defmacrop half(x) do
                 quote do: div(unquote(x), 2)
               end

               @doc "Halves."
               def run(x), do: half(x)
             end
             """) =~ "defmacrop is not permitted by your policy"
    end

    test "allow_defmacro admits macro definitions" do
      assert {:ok, [Scan.Fixture.M]} =
               scan_define(@macro_module, policy(rules: [allow_defmacro: true]))
    end

    test "the qualified Kernel.defmacro spelling is closed and reopens with the rule" do
      code = """
      defmodule Scan.Fixture.MQ do
        @moduledoc "MQ."

        Kernel.defmacro double(x) do
          quote do: unquote(x) * 2
        end
      end
      """

      assert scan_define_error(code) =~ "defmacro is not permitted by your policy"

      assert {:ok, [Scan.Fixture.MQ]} =
               scan_define(code, policy(rules: [allow_defmacro: true]))
    end

    test "defguard stays outside the rule" do
      assert {:ok, _modules} =
               scan_define("""
               defmodule Scan.Fixture.G do
                 @moduledoc "G."

                 @doc "True for adults."
                 defguard is_adult(age) when is_integer(age) and age >= 18
               end
               """)
    end
  end

  describe "the data surface" do
    test "the Host.Repo query family passes" do
      assert :ok = scan(~s|Host.Repo.query("select 1")|)
      assert :ok = scan(~s|Host.Repo.query_many!("select 1", [], [])|)
    end

    test "the repo's process controls are denied without a hint" do
      assert scan_error("Host.Repo.put_dynamic_repo(Beamlet.Repo)") =~
               ~r/Host\.Repo\.put_dynamic_repo\/1 is not permitted by your policy$/
    end

    test "Ecto queries and changesets pass, imports included" do
      assert :ok =
               scan("""
               import Ecto.Query
               query = from(r in "rows", where: r.x > 1, select: count(r.id))
               Host.Repo.one(query)
               """)

      assert :ok =
               scan("""
               import Ecto.Changeset
               {%{}, %{name: :string}} |> cast(%{name: "x"}, [:name]) |> validate_required([:name])
               """)
    end

    test "Ecto.Repo and the SQL adapter redirect to Host.Repo" do
      assert scan_error("Ecto.Repo.all(Beamlet.Repo)") =~
               "Ecto.Repo is not permitted by your policy — " <>
                 "the agent database is reached through Host.Repo"

      assert scan_error(~s|Ecto.Adapters.SQL.query(Host.Repo, "select 1")|) =~
               "the agent database is reached through Host.Repo"
    end

    test "Ecto's exceptions can be rescued" do
      assert :ok =
               scan("""
               try do
                 Host.Repo.one!(Ecto.Query.from(r in "rows"))
               rescue
                 Ecto.NoResultsError -> nil
                 e in Ecto.ConstraintError -> e.constraint
               end
               """)
    end

    test "a schema module passes the define scan" do
      assert {:ok, [Scan.Fixture.Item]} =
               scan_define("""
               defmodule Scan.Fixture.Item do
                 @moduledoc "Item."
                 use Ecto.Schema
                 import Ecto.Changeset

                 schema "items" do
                   field :name, :string
                   timestamps()
                 end

                 @doc "Casts."
                 def changeset(item, attrs), do: item |> cast(attrs, [:name]) |> validate_required([:name])
               end
               """)
    end

    test "Ecto.Migration.execute passes; execute_file reads a real path" do
      assert :ok = scan(~s|Ecto.Migration.execute("create view v as select 1")|)

      assert scan_error(~s|Ecto.Migration.execute_file("x.sql")|, @doors_open) =~
               "Ecto.Migration.execute_file/1 is not permitted by your policy — " <>
                 "Host.File provides scoped file access"
    end
  end

  describe "the dispatch rule" do
    @relaxed Policy.build(:x, rules: [allow_dynamic_dispatch: true]) |> elem(1)

    test "a variable call target passes in eval" do
      assert :ok = scan("mod = Enum\nmod.sum([1])", @relaxed)
    end

    test "a variable capture target passes in eval" do
      assert :ok = scan("mod = Enum\nEnum.map([[1]], &mod.sum/1)", @relaxed)
    end

    test "a variable call target passes in define" do
      assert {:ok, [Scan.Fixture.D]} =
               scan_define(
                 """
                 defmodule Scan.Fixture.D do
                   @moduledoc "D."

                   @doc "Dispatches."
                   def run(mod), do: mod.sum([1])
                 end
                 """,
                 @relaxed
               )
    end

    test "a denied literal module is still denied" do
      assert scan_error("File.read!(\"x\")", @relaxed) =~ "File is not permitted"
    end

    test "alias, import, require and use targets must still be literal" do
      assert scan_error("alias {:x, :y}\n", @relaxed) =~ "unsupported alias form"

      assert scan_error("import unquote(:mod)", @relaxed) =~
               "import target must be a literal module"

      assert scan_error("require unquote(:mod)", @relaxed) =~
               "require target must be a literal module"
    end

    test "data-position expansion targets must still be literal" do
      assert scan_define_error(
               """
               defmodule Scan.Fixture.DD do
                 @moduledoc "DD."

                 @doc "Delegates."
                 defdelegate sum(list), to: unquote(:mod)
               end
               """,
               @relaxed
             ) =~ "defdelegate to: must be a literal module"

      assert scan_define_error(
               """
               defmodule Scan.Fixture.DH do
                 @moduledoc "DH."
                 @before_compile unquote(:mod)
               end
               """,
               @relaxed
             ) =~ "@before_compile target must be a literal module"
    end

    test "map field access on a variable still passes unchanged" do
      assert :ok = scan("m = %{a: 1}\nm.a", @relaxed)
    end
  end
end
