defmodule Beamlet.Principal do
  @moduledoc """
  What a request acts as: the user and token behind it and the policy
  its code runs under.

  Built once per request by `Beamlet.MCP.Plug` from the token the
  request presented, and never stored. Every eval, define, commit and
  route keys on it: authorization asks what this principal may do,
  provenance records which principal did it.

      %Beamlet.Principal{
        user_id: 1, user_name: "alice",
        token_id: 3, token_name: "laptop",
        policy: "default"
      }

  Names and ids both, since a reader wants the name and a program
  wants the id after a rename.

  Code an agent runs through `eval` takes no arguments, so it cannot
  be handed the principal, and the stdlib functions it calls must
  still know who is acting when they record it. The runtime puts the
  principal in the evaluating process before the code runs
  (`put_current/1`) and those functions read it back (`current/0`).
  Outside evaluated code, in a web request or a test process, there
  is none and `current/0` is nil. A tool that holds the principal
  itself passes it explicitly.
  """

  alias Beamlet.Token
  alias Beamlet.User

  defstruct [:user_id, :user_name, :token_id, :token_name, :policy]

  @key {Beamlet, :principal}

  @typedoc "A request's principal."
  @type t :: %__MODULE__{
          user_id: pos_integer(),
          user_name: String.t(),
          token_id: pos_integer(),
          token_name: String.t(),
          policy: String.t()
        }

  @doc "Builds the principal for a token whose user is loaded, as `Beamlet.Users.authenticate/1` returns it."
  @spec from_token(Token.t()) :: t()
  def from_token(%Token{user: %User{} = user} = token) do
    %__MODULE__{
      user_id: user.id,
      user_name: user.name,
      token_id: token.id,
      token_name: token.name,
      policy: token.policy
    }
  end

  @doc "Makes `principal` the one the current process acts as; eval's runtime calls it before evaluating."
  @spec put_current(t()) :: :ok
  def put_current(%__MODULE__{} = principal) do
    Process.put(@key, principal)
    :ok
  end

  @doc "The principal evaluated code runs as, or nil outside an eval."
  @spec current() :: t() | nil
  def current, do: Process.get(@key)
end
