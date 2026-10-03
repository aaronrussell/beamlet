defmodule Beamlet.Principal do
  @moduledoc false

  # What a request acts as: the token behind it and the policy its code
  # runs under.
  #
  # Built once per request by `Beamlet.MCP.Plug` from the token the
  # request presented, and never stored. Every eval, define, commit and
  # route keys on it: authorization asks what this principal may do,
  # provenance records which principal did it.
  #
  #     %Beamlet.Principal{token_id: 3, token_label: "laptop", policy: "default"}
  #
  # The label and the id both, since a reader wants the label and a
  # program wants the id after a rename. The token is carried by its
  # label (`Beamlet.Token.label/1`): a `cli` token's name, or the host
  # of an `oauth` token's client id, so a commit reads `Token: laptop (3)`
  # or `Token: claude.ai (7)`.
  #
  # Provenance is this struct written down. A commit the code server
  # makes carries it as git trailers (`to_trailers/1`), which git parses
  # natively, so `git log` can filter the history by token or policy
  # with no code of Beamlet's; a route row (`Beamlet.Route`) carries it
  # as JSON (`to_map/1`). Both encodings decode back to the struct.
  #
  #     Token: laptop (3)
  #     Policy: default
  #
  #     {"token": {"id": 3, "label": "laptop"}, "policy": "default"}
  #
  # A principal is a token acting through a tool. A web request has no
  # principal: a served route acts as nobody, and a future web identity
  # is the owner on the request, never a principal in the process.
  #
  # Code an agent runs through `eval` takes no arguments, so it cannot
  # be handed the principal, and the stdlib functions it calls must
  # still know who is acting when they record it. The runtime puts the
  # principal in the evaluating process before the code runs
  # (`put_current/1`) and those functions read it back (`current/0`, or
  # `current!/1` to raise without one). Outside evaluated code, in a web
  # request or a test process, there is none and `current/0` is nil. A
  # tool that holds the principal itself passes it explicitly.
  #
  # What the beamlet does on its own behalf, such as sweeping hand
  # edits into a commit at boot, is recorded under the system principal
  # (`system/0`): the token `beamlet` with id 0, which the database
  # never issues, under the `default` policy. The token name `beamlet`
  # is reserved so the record never names two things.

  alias Beamlet.Token

  defstruct [:token_id, :token_label, :policy]

  @key {Beamlet, :principal}

  @typedoc "A request's principal."
  @type t :: %__MODULE__{
          token_id: non_neg_integer(),
          token_label: String.t(),
          policy: String.t()
        }

  @doc "Builds the principal for a token."
  @spec from_token(Token.t()) :: t()
  def from_token(%Token{} = token) do
    %__MODULE__{token_id: token.id, token_label: Token.label(token), policy: token.policy}
  end

  @doc "The principal the beamlet acts as on its own behalf: `beamlet`, id 0, the default policy."
  @spec system() :: t()
  def system do
    %__MODULE__{token_id: 0, token_label: "beamlet", policy: "default"}
  end

  @doc "Encodes the principal as git trailers, `Token: label (id)` and `Policy: name`, for a commit message."
  @spec to_trailers(t()) :: String.t()
  def to_trailers(%__MODULE__{} = principal) do
    "Token: #{principal.token_label} (#{principal.token_id})\n" <>
      "Policy: #{principal.policy}\n"
  end

  @doc "Decodes the trailers back to the principal, from a commit message or the trailer block alone."
  @spec from_trailers(String.t()) :: {:ok, t()} | :error
  def from_trailers(text) when is_binary(text) do
    with [_, token_label, token_id] <- Regex.run(~r/^Token: (\S+) \((\d+)\)$/m, text),
         [_, policy] <- Regex.run(~r/^Policy: (\S+)$/m, text) do
      {:ok,
       %__MODULE__{
         token_id: String.to_integer(token_id),
         token_label: token_label,
         policy: policy
       }}
    else
      nil -> :error
    end
  end

  @doc "Encodes the principal as the map a route row stores as JSON: the token's id and label nested under `token`, and the policy."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = principal) do
    %{
      "token" => %{"id" => principal.token_id, "label" => principal.token_label},
      "policy" => principal.policy
    }
  end

  @doc "Decodes the map back to the principal; `:error` when a part is missing or malformed."
  @spec from_map(map()) :: {:ok, t()} | :error
  def from_map(%{"token" => %{"id" => token_id, "label" => token_label}, "policy" => policy})
      when is_integer(token_id) and is_binary(token_label) and is_binary(policy) do
    {:ok, %__MODULE__{token_id: token_id, token_label: token_label, policy: policy}}
  end

  def from_map(_other), do: :error

  @doc "Makes `principal` the one the current process acts as; eval's runtime calls it before evaluating."
  @spec put_current(t()) :: :ok
  def put_current(%__MODULE__{} = principal) do
    Process.put(@key, principal)
    :ok
  end

  @doc "The principal evaluated code runs as, or nil outside an eval."
  @spec current() :: t() | nil
  def current, do: Process.get(@key)

  @doc """
  The principal evaluated code runs as, raising outside an eval.

  `caller` names the function that needs it, e.g. `"Host.Router.live"`,
  so the teaching error says which call cannot work here.
  """
  @spec current!(String.t()) :: t()
  def current!(caller) do
    current() ||
      raise "#{caller} works from eval, where your code acts as you; " <>
              "there is no principal in this process"
  end

  @doc "Removes the current process's principal, so the code that follows acts as nobody; `Host.Router.call/4` does this around a request."
  @spec delete_current() :: :ok
  def delete_current do
    Process.delete(@key)
    :ok
  end
end
