defmodule Beamlet.Case do
  @moduledoc """
  Test case for anything that needs a running beamlet.

  Starts one under the test supervisor against the configured
  per-run data dir and hands the path to the test as `data_dir`.
  Each test owns a sandbox connection on both repos, shared with
  every process in the VM, so rows written during a test roll back
  when it ends while the schema migrated at boot stays.

  Every test also gets a user, `alice`, and one of her tokens as
  `user` and `token`, created through `Beamlet.Users` so a test
  authenticates the way production does. The token still carries its
  `secret`.

  A test declares policies for its beamlet with a tag in the shape
  config takes, put into config before the beamlet starts and removed
  after:

      @tag policies: [restricted: [tools: [:eval]]]
  """

  use ExUnit.CaseTemplate

  alias Ecto.Adapters.SQL.Sandbox

  using do
    quote do
      import Beamlet.Case
    end
  end

  setup context do
    if policies = context[:policies] do
      Application.put_env(:beamlet, :policies, policies)
      on_exit(fn -> Application.delete_env(:beamlet, :policies) end)
    end

    start_supervised!({Beamlet, []})

    for repo <- [Beamlet.Repo, Host.Repo] do
      owner = Sandbox.start_owner!(repo, shared: true)
      on_exit(fn -> Sandbox.stop_owner(owner) end)
    end

    {:ok, user} = Beamlet.Users.create(name: "alice")
    {:ok, token} = Beamlet.Users.create_token(user, name: "test")

    %{data_dir: Beamlet.Config.data_dir(), user: user, token: token}
  end

  @doc "Changeset errors as a map of field to messages, with values interpolated."
  @spec errors_on(Ecto.Changeset.t()) :: %{atom() => [String.t()]}
  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
