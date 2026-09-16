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

  Provenance is this struct written down. A commit the code server
  makes carries it as git trailers (`to_trailers/1`), which git parses
  natively, so `git log` can filter the history by token or policy
  with no code of Beamlet's; a route row will carry it as JSON. Both
  encodings decode back to the struct.

      User: alice (1)
      Token: laptop (3)
      Policy: default

  Code an agent runs through `eval` takes no arguments, so it cannot
  be handed the principal, and the stdlib functions it calls must
  still know who is acting when they record it. The runtime puts the
  principal in the evaluating process before the code runs
  (`put_current/1`) and those functions read it back (`current/0`).
  Outside evaluated code, in a web request or a test process, there
  is none and `current/0` is nil. A tool that holds the principal
  itself passes it explicitly.

  What the beamlet does on its own behalf, such as sweeping hand
  edits into a commit at boot, is recorded under the system principal
  (`system/0`): user and token both named `beamlet` with id 0, which
  the database never issues, under the `default` policy. The user
  name `beamlet` is reserved so the record never names two things.
  """

  alias Beamlet.Token
  alias Beamlet.User

  defstruct [:user_id, :user_name, :token_id, :token_name, :policy]

  @key {Beamlet, :principal}

  @typedoc "A request's principal."
  @type t :: %__MODULE__{
          user_id: non_neg_integer(),
          user_name: String.t(),
          token_id: non_neg_integer(),
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

  @doc "The principal the beamlet acts as on its own behalf: `beamlet`, id 0, the default policy."
  @spec system() :: t()
  def system do
    %__MODULE__{
      user_id: 0,
      user_name: "beamlet",
      token_id: 0,
      token_name: "beamlet",
      policy: "default"
    }
  end

  @doc "Encodes the principal as git trailers, one `Key: name (id)` line each, for a commit message."
  @spec to_trailers(t()) :: String.t()
  def to_trailers(%__MODULE__{} = principal) do
    "User: #{principal.user_name} (#{principal.user_id})\n" <>
      "Token: #{principal.token_name} (#{principal.token_id})\n" <>
      "Policy: #{principal.policy}\n"
  end

  @doc "Decodes the trailers back to the principal, from a commit message or the trailer block alone."
  @spec from_trailers(String.t()) :: {:ok, t()} | :error
  def from_trailers(text) when is_binary(text) do
    with [_, user_name, user_id] <- Regex.run(~r/^User: (\S+) \((\d+)\)$/m, text),
         [_, token_name, token_id] <- Regex.run(~r/^Token: (\S+) \((\d+)\)$/m, text),
         [_, policy] <- Regex.run(~r/^Policy: (\S+)$/m, text) do
      {:ok,
       %__MODULE__{
         user_id: String.to_integer(user_id),
         user_name: user_name,
         token_id: String.to_integer(token_id),
         token_name: token_name,
         policy: policy
       }}
    else
      nil -> :error
    end
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
