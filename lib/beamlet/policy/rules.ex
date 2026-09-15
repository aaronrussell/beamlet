defmodule Beamlet.Policy.Rules do
  @moduledoc """
  The shape rules a policy applies to submitted code.

  Both are submission rules: they govern what a token may author into
  the shared pool of modules, never what it may call. Both default
  strict, and a policy relaxes one under its `rules` key
  (`Beamlet.Policy` explains what each relaxation reaches):

      rules: [allow_defmacro: true]

  `allow_defmacro` permits `defmacro` and `defmacrop` in `define`.
  `allow_dynamic_dispatch` permits call targets that are not literal
  modules, such as `mod.fun()` with `mod` a variable.
  """

  defstruct allow_defmacro: false, allow_dynamic_dispatch: false

  @typedoc "The rules in force for a policy; both default strict."
  @type t :: %__MODULE__{allow_defmacro: boolean(), allow_dynamic_dispatch: boolean()}

  @doc "The rule names a policy may set."
  @spec keys() :: [atom()]
  def keys, do: [:allow_defmacro, :allow_dynamic_dispatch]
end
