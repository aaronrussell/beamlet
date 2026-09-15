defmodule Beamlet.PolicyTest do
  use ExUnit.Case, async: true

  alias Beamlet.Policy
  alias Beamlet.Policy.Default
  alias Beamlet.Policy.Rules

  describe "default/0" do
    test "is named default with both tools, strict rules and the curated grants" do
      policy = Policy.default()

      assert policy.name == "default"
      assert policy.tools == [:define, :eval]
      assert policy.rules == %Rules{}
      assert policy.grants == Default.grants()
    end
  end

  describe "build/2" do
    test "an empty document is the default under a new name" do
      assert {:ok, policy} = Policy.build(:explorer, [])
      assert policy == %{Policy.default() | name: "explorer"}
    end

    test "accepts a string name" do
      assert {:ok, %Policy{name: "explorer"}} = Policy.build("explorer", [])
    end

    test "tools replaces the default's list" do
      assert {:ok, %Policy{tools: [:eval]}} = Policy.build(:x, tools: [:eval])
      assert {:ok, %Policy{tools: []}} = Policy.build(:x, tools: [])
    end

    test "rules merge, leaving the others strict" do
      assert {:ok, policy} = Policy.build(:x, rules: [allow_defmacro: true])
      assert policy.rules == %Rules{allow_defmacro: true, allow_dynamic_dispatch: false}
    end

    test "allow adds a module" do
      assert {:ok, policy} = Policy.build(:x, allow: [Task])
      assert Policy.allowed?(policy, Task, :async, 1)
    end

    test "allow replaces an entry wholesale" do
      assert {:ok, policy} = Policy.build(:x, allow: [Kernel])
      assert Policy.allowed?(policy, Kernel, :apply, 2)
    end

    test "allow with only grants exactly the listed functions" do
      assert {:ok, policy} = Policy.build(:x, allow: [{File, only: [read: 1]}])
      assert Policy.allowed?(policy, File, :read, 1)
      refute Policy.allowed?(policy, File, :write, 2)
    end

    test "allow with except grants all but the listed functions" do
      assert {:ok, policy} = Policy.build(:x, allow: [{IO, except: [gets: 1]}])
      assert Policy.allowed?(policy, IO, :write, 1)
      refute Policy.allowed?(policy, IO, :gets, 1)
    end

    test "deny removes an entry" do
      assert {:ok, policy} = Policy.build(:x, deny: [IO])
      refute Policy.allowed?(policy, IO)
      refute Policy.allowed?(policy, IO, :puts, 1)
    end

    test "deny of a module nothing grants is a no-op" do
      assert {:ok, policy} = Policy.build(:x, deny: [File])
      assert policy.grants == Policy.default().grants
    end

    test "deny applies after allow, so a module in both is denied" do
      assert {:ok, policy} = Policy.build(:x, allow: [File], deny: [File])
      refute Policy.allowed?(policy, File)
    end

    test "rejects the reserved name" do
      assert {:error, message} = Policy.build(:default, [])
      assert message =~ "policy default: the name is reserved"
    end

    test "rejects a name outside the name rule" do
      assert {:error, message} = Policy.build("Explorer", [])
      assert message =~ ~s(policy "Explorer": names are lowercase letters)

      assert {:error, _} = Policy.build(String.duplicate("a", 65), [])
    end

    test "rejects a document that is not a keyword list" do
      assert {:error, message} = Policy.build(:x, %{tools: [:eval]})
      assert message =~ "policy x: a policy is a keyword list"
    end

    test "rejects an unknown key" do
      assert {:error, message} = Policy.build(:x, allow_app: [:req])

      assert message =~
               "policy x: unknown key :allow_app (a policy has tools, rules, allow and deny)"
    end

    test "rejects tools outside the list" do
      assert {:error, message} = Policy.build(:x, tools: [:eval, :exec])

      assert message =~
               "policy x: tools must be a list drawn from [:define, :eval], got: [:eval, :exec]"

      assert {:error, message} = Policy.build(:x, tools: :eval)
      assert message =~ "policy x: tools must be a list"
    end

    test "rejects a tool named twice" do
      assert {:error, message} = Policy.build(:x, tools: [:eval, :eval])
      assert message =~ "policy x: tools names :eval twice"
    end

    test "rejects an unknown rule" do
      assert {:error, message} = Policy.build(:x, rules: [allow_raw_sql: true])

      assert message =~
               "policy x: unknown rule :allow_raw_sql (rules are allow_defmacro and allow_dynamic_dispatch)"
    end

    test "rejects a rule that is not a boolean" do
      assert {:error, message} = Policy.build(:x, rules: [allow_defmacro: "yes"])
      assert message =~ ~s(policy x: rule allow_defmacro must be true or false, got: "yes")
    end

    test "rejects rules that are not a keyword list" do
      assert {:error, message} = Policy.build(:x, rules: true)
      assert message =~ "policy x: rules must be a keyword list"
    end

    test "rejects allow and deny that are not lists" do
      assert {:error, message} = Policy.build(:x, allow: Task)
      assert message =~ "policy x: allow must be a list of modules, got: Task"

      assert {:error, message} = Policy.build(:x, deny: Task)
      assert message =~ "policy x: deny must be a list of modules, got: Task"
    end

    test "rejects a module that is not loadable, under allow and under deny" do
      assert {:error, message} = Policy.build(:x, allow: [Nope.Missing])
      assert message =~ "policy x: allow Nope.Missing is not a module on this beamlet"
      assert message =~ "existence is the grant"

      assert {:error, message} = Policy.build(:x, deny: [Nope.Missing])
      assert message =~ "policy x: deny Nope.Missing is not a module on this beamlet"

      assert {:error, message} = Policy.build(:x, allow: ["Task"])
      assert message =~ "policy x: allow entries are a module"
    end

    test "rejects both only and except, and any other option" do
      assert {:error, message} =
               Policy.build(:x, allow: [{File, only: [read: 1], except: [rm: 1]}])

      assert message =~ "policy x: allow File takes only: or except:, not both"

      assert {:error, message} = Policy.build(:x, allow: [{File, functions: [read: 1]}])
      assert message =~ "policy x: allow File takes only: or except:, got: [functions: [read: 1]]"
    end

    test "rejects a malformed function list" do
      assert {:error, message} = Policy.build(:x, allow: [{File, only: []}])

      assert message =~
               "policy x: allow File only: must be a non-empty list of function: arity pairs"

      assert {:error, message} = Policy.build(:x, allow: [{File, except: [read: -1]}])
      assert message =~ "policy x: allow File except: must be a non-empty list"

      assert {:error, message} = Policy.build(:x, allow: [{File, only: [:read]}])
      assert message =~ "policy x: allow File only: must be a non-empty list"
    end

    test "rejects a function the module does not export at that arity" do
      assert {:error, message} = Policy.build(:x, allow: [{File, only: [raed: 1]}])
      assert message =~ "policy x: allow File only: raed/1 is not a function or macro of File"

      assert {:error, message} = Policy.build(:x, allow: [{File, except: [read: 3]}])
      assert message =~ "policy x: allow File except: read/3 is not a function or macro of File"
    end

    test "accepts macros in a function list" do
      assert {:ok, policy} = Policy.build(:x, allow: [{Kernel, except: [def: 2]}])
      refute Policy.allowed?(policy, Kernel, :def, 2)
      assert Policy.allowed?(policy, Kernel, :apply, 2)
    end

    test "rejects a module named twice in one key" do
      assert {:error, message} = Policy.build(:x, allow: [File, {File, only: [read: 1]}])
      assert message =~ "policy x: allow names File twice"

      assert {:error, message} = Policy.build(:x, deny: [IO, IO])
      assert message =~ "policy x: deny names IO twice"
    end
  end

  describe "allowed?/4 and fetch/2" do
    test "only grants exactly the listed pairs" do
      policy = %Policy{grants: %{Req => {:only, [get: 2]}}}

      assert Policy.allowed?(policy, Req, :get, 2)
      refute Policy.allowed?(policy, Req, :get, 1)
      refute Policy.allowed?(policy, Req, :post, 2)
      assert Policy.fetch(policy, Req) == {:ok, {:only, [get: 2]}}
    end

    test "except grants everything but the listed pairs" do
      policy = %Policy{grants: %{Req => {:except, [post: 2]}}}

      assert Policy.allowed?(policy, Req, :get, 2)
      refute Policy.allowed?(policy, Req, :post, 2)
    end

    test "an absent module denies every function" do
      policy = %Policy{grants: %{}}

      refute Policy.allowed?(policy, Req)
      refute Policy.allowed?(policy, Req, :get, 2)
      assert Policy.fetch(policy, Req) == :error
    end
  end

  describe "render/1" do
    test "opens with the name and tools" do
      text = Policy.render(Policy.default())
      assert String.starts_with?(text, "Policy: default\nTools: define, eval\n")

      {:ok, policy} = Policy.build(:x, tools: [])
      assert Policy.render(policy) =~ "Tools: (none)"
    end

    test "renders the deliberate denials with their reasons" do
      text = Policy.render(Policy.default())

      assert text =~ ~r/File.*\n.*Host\.FS provides scoped file access/
      assert text =~ "concurrency primitives are not available to agent code yet"
      assert text =~ "environment and application config are not readable"
      assert text =~ ~r/Ecto\.Repo.*\n.*the agent database is reached through Host\.Repo/
    end

    test "renders the partial grants' carve-outs" do
      text = Policy.render(Policy.default())

      assert text =~ ~r/^  Kernel — all except apply\/2/m
      assert text =~ ~r/^  System — only convert_time_unit\/3/m
      assert text =~ ~r/^  :erlang — only adler32\/1/m
      assert text =~ ~r/^  Host\.Repo — all except disconnect_all\/1, .*put_dynamic_repo\/1, /m
    end

    test "a re-granted module drops off the denial list" do
      {:ok, policy} = Policy.build(:x, allow: [File])
      text = Policy.render(policy)

      refute text =~ ~r/^  .*\bFile,/m
      assert text =~ "File.Stat"
    end

    test "renders the rules in force for strict rules" do
      text = Policy.render(Policy.default())

      assert text =~ "Rules for your code:"
      assert text =~ "defmacro/defmacrop are not permitted in define"
      assert text =~ "call targets must be literal modules"
    end

    test "a relaxed rule says nothing" do
      {:ok, policy} = Policy.build(:x, rules: [allow_defmacro: true])
      text = Policy.render(policy)
      assert text =~ "call targets must be literal modules"
      refute text =~ "defmacro/defmacrop"

      {:ok, policy} =
        Policy.build(:x, rules: [allow_defmacro: true, allow_dynamic_dispatch: true])

      text = Policy.render(policy)
      assert text =~ "Rules for your code:\n  (none)"
      refute text =~ "call targets must be literal modules"
    end

    test "a policy withholding nothing says so" do
      policy = %Policy{name: "open", grants: Map.new(Default.signage_modules(), &{&1, :all})}
      assert Policy.render(policy) =~ "Not available:\n  (nothing withheld)"
    end
  end
end
