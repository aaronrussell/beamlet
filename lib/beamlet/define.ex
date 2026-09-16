defmodule Beamlet.Define do
  @moduledoc """
  Define modules on your beamlet: the runtime behind the `define`
  tool.

  A buffer of one or more top-level `defmodule`s is scanned against
  the principal's policy (`Beamlet.Scanner`), checked for docs, then
  handed to the code server (`Beamlet.Code`), which compiles it into
  the running beamlet, writes one source file per module and commits
  the change with the principal as provenance. The modules are
  callable from `eval` and from other modules the moment the define
  returns, and are reloaded at boot.

  The buffer's rules, each refused with a teaching error:

  - Top-level `defmodule`s only. An expression is for `eval`; a
    nested module is defined as its own top-level one.
  - Every module has a `@moduledoc` and every public function a
    `@doc`, because docs are how a module is found later.
  - The policy applies inside module bodies exactly as it does in
    `eval`, and a denied call is refused before anything compiles.
  - `Beamlet.*` and `Host.*` are reserved; a name any loaded module
    already has is refused; redefining a module defined before
    needs `replace: true`, and that flag is harmless on a new module.

  The result is a summary, one line per module:

      {:ok, "Defined Shopping.List (new)"} =
        Beamlet.Define.run(code, principal)

  A replace recompiles the module's dependents and names them; a
  dependent that no longer compiles, or a caller of a function the
  replacement dropped, fails the whole define with nothing changed.

  One limit, set in config: `timeout` (30 seconds) is how long one
  compile may take, since a define holds the code server's single
  lane. On any error, a timeout included, nothing is changed.

      config :beamlet, define: [timeout: 30_000]
  """

  alias Beamlet.Code
  alias Beamlet.Code.Docs
  alias Beamlet.Policies
  alias Beamlet.Policy
  alias Beamlet.Principal
  alias Beamlet.Scanner

  @doc """
  Scans, checks and defines the modules in `code` as `principal`,
  returning the summary or the error text.

  `opts`: `replace: true` permits redefining modules defined before;
  `timeout` overrides the configured compile timeout for this run.
  """
  @spec run(String.t(), Principal.t(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def run(code, %Principal{} = principal, opts \\ []) when is_binary(code) do
    {:ok, policy} = Policies.fetch(principal.policy)
    policy = Policy.grant(policy, Code.defined())
    replace? = Keyword.get(opts, :replace, false)

    with {:ok, modules} <- Scanner.scan_define(code, policy),
         :ok <- Docs.check(code) do
      Code.define(code, modules, replace?, principal, Keyword.take(opts, [:timeout]))
    end
  end
end
