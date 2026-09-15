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
  """

  alias Beamlet.Token
  alias Beamlet.User

  defstruct [:user_id, :user_name, :token_id, :token_name, :policy]

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
end
