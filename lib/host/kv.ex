defmodule Host.KV do
  @moduledoc """
  Durable key/value storage for small state under string keys.

  A cursor, a last-run time, a preference: any Elixir term, and
  values come back exactly as stored. Keys are one shared namespace
  across every agent and module on your beamlet, so prefix yours
  with your domain, e.g. `"poller:last_id"`. The store lives in the
  agent database beside your own tables, so a write here inside a
  `Host.Repo.transaction` lands together with your rows:

      def create(conn, %{"id" => id} = event) do
        Host.Repo.transaction(fn ->
          Host.Repo.insert!(Events.Event.changeset(%Events.Event{}, event))
          Host.KV.put("events:last_id", id)
        end)

        json(conn, %{ok: true})
      end

  Anything you would filter, sort or join on belongs in a table of
  its own, through a migration (`Host.Migrator`) and an
  `Ecto.Schema`, and so does a total you increment: count the rows,
  or keep a counter row the database bumps in one upsert, since a
  read-increment-write here loses updates under concurrent requests.
  Reads return the value or a default; `fetch/1` is the one that
  tells a stored `nil` from a missing key.
  """

  import Ecto.Query

  alias Beamlet.KV.Entry

  @doc """
  Returns `{:ok, value}` for the value stored under `key`, or
  `:error` when there is none. The only read that distinguishes a
  stored `nil` from a missing key.
  """
  @spec fetch(String.t()) :: {:ok, term()} | :error
  def fetch(key) when is_binary(key) do
    case Host.Repo.get(Entry, key) do
      nil -> :error
      %Entry{value: value} -> {:ok, value}
    end
  end

  @doc """
  Returns the value stored under `key`, or `default` when there is
  none, e.g. `get("poller:last_id", 0)`.
  """
  @spec get(String.t(), term()) :: term()
  def get(key, default \\ nil) when is_binary(key) do
    case fetch(key) do
      {:ok, value} -> value
      :error -> default
    end
  end

  @doc """
  Stores `value` under `key`, replacing any existing value, e.g.
  `put("poller:last_id", 42)`. Any term is accepted.
  """
  @spec put(String.t(), term()) :: :ok
  def put(key, value) when is_binary(key) do
    Host.Repo.insert_all(Entry, [%{key: key, value: value}],
      on_conflict: {:replace, [:value]},
      conflict_target: :key
    )

    :ok
  end

  @doc "Removes `key`. Removing a key that is not there is a no-op."
  @spec delete(String.t()) :: :ok
  def delete(key) when is_binary(key) do
    Host.Repo.delete_all(from(e in Entry, where: e.key == ^key))
    :ok
  end

  @doc """
  Returns every entry whose key starts with `prefix` as a map of key
  to value, loaded in one query, e.g. `all("poller:")`. Use this
  rather than `get/2` in a loop; `keys/1` lists the keys alone when
  the values are not needed. An empty prefix returns everything.
  """
  @spec all(String.t()) :: %{String.t() => term()}
  def all(prefix \\ "") when is_binary(prefix) do
    prefix
    |> under()
    |> select([e], {e.key, e.value})
    |> Host.Repo.all()
    |> Map.new()
  end

  @doc """
  Returns every key starting with `prefix`, sorted, without loading
  the values, e.g. `keys("poller:")`. `all/1` returns keys and
  values together. An empty prefix lists every key.
  """
  @spec keys(String.t()) :: [String.t()]
  def keys(prefix \\ "") when is_binary(prefix) do
    prefix
    |> under()
    |> order_by([e], e.key)
    |> select([e], e.key)
    |> Host.Repo.all()
  end

  @doc """
  Removes every key starting with `prefix` in one query, e.g.
  `delete_all("poller:")`. An empty prefix removes every key.
  """
  @spec delete_all(String.t()) :: :ok
  def delete_all(prefix) when is_binary(prefix) do
    prefix |> under() |> Host.Repo.delete_all()
    :ok
  end

  # Prefix matching is SQLite GLOB, which walks the primary key's
  # B-tree (the table is WITHOUT ROWID); the prefix's own wildcard
  # characters are escaped so they match literally.
  defp under(""), do: from(e in Entry)

  defp under(prefix) do
    pattern = glob_escape(prefix) <> "*"
    from(e in Entry, where: fragment("? GLOB ?", e.key, ^pattern))
  end

  defp glob_escape(prefix) do
    String.replace(prefix, ["*", "?", "["], fn
      "*" -> "[*]"
      "?" -> "[?]"
      "[" -> "[[]"
    end)
  end
end
