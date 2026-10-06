defmodule Host.KV do
  @moduledoc """
  Durable key/value storage for small state under string keys.

  A cursor, a counter, a last-run time, a preference. Values are
  JSON: `nil`, booleans, numbers, strings, lists, and maps with
  string keys, and what you put is what you get back. Anything else
  raises on `put/2`, so store an atom as a string (`"active"` rather
  than `:active`), a map with string keys (`%{"count" => 1}` rather
  than `%{count: 1}`) and a time as ISO 8601
  (`DateTime.to_iso8601(now)`).

  Keys are one shared namespace across every agent and module on your
  beamlet, so prefix yours with your domain, e.g. `"poller:last_id"`.
  The store lives in the agent database beside your own tables, so a
  write here inside a `Host.Repo.transaction` lands together with
  your rows:

      def create(conn, %{"id" => id} = event) do
        Host.Repo.transaction(fn ->
          Host.Repo.insert!(Events.Event.changeset(%Events.Event{}, event))
          Host.KV.put("events:last_id", id)
        end)

        json(conn, %{ok: true})
      end

  A value worked out from the one before it, a counter or a list of
  recent ids, changes through `update/3`, since a `get/2` then a
  `put/2` loses updates under concurrent requests. Anything you would
  filter, sort or join on belongs in a table of its own, through a
  migration (`Host.Migrator`) and an `Ecto.Schema`. Reads return the
  value or a default; `fetch/1` is the one that tells a stored `nil`
  from a missing key.
  """

  import Ecto.Query

  alias Beamlet.KV.Entry

  @retry_ms 1_000

  @typedoc "A value the store holds: JSON's shapes, with maps keyed by strings."
  @type value ::
          nil
          | boolean()
          | number()
          | String.t()
          | [value()]
          | %{optional(String.t()) => value()}

  @doc """
  Returns `{:ok, value}` for the value stored under `key`, or
  `:error` when there is none.

  The only read that distinguishes a stored `nil` from a missing key.
  """
  @spec fetch(String.t()) :: {:ok, value()} | :error
  def fetch(key) when is_binary(key) do
    case Host.Repo.get(Entry, key) do
      nil -> :error
      %Entry{value: text} -> {:ok, decode!(key, text)}
    end
  end

  @doc """
  Returns the value stored under `key`, or `default` when there is
  none, e.g. `get("poller:last_id", 0)`.
  """
  @spec get(String.t(), term()) :: value() | term()
  def get(key, default \\ nil) when is_binary(key) do
    case fetch(key) do
      {:ok, value} -> value
      :error -> default
    end
  end

  @doc """
  Stores `value` under `key`, replacing any existing value, e.g.
  `put("poller:last_id", 42)`.

  A value that is not JSON-shaped (`t:value/0`) raises
  `ArgumentError` naming where in the value the problem sits, and
  nothing is written.
  """
  @spec put(String.t(), value()) :: :ok
  def put(key, value) when is_binary(key) do
    check!(value, [])

    Host.Repo.insert_all(Entry, [%{key: key, value: JSON.encode!(value)}],
      on_conflict: {:replace, [:value]},
      conflict_target: :key
    )

    :ok
  end

  @doc """
  Updates the value under `key` with `fun` and returns the new value,
  storing `default` as it is when the key is missing, e.g.
  `update("api:hits", 1, &(&1 + 1))`.

  No update is lost under concurrent requests: if another write lands
  on `key` while `fun` runs, `fun` runs again on the newer value. So
  keep `fun` fast and pure, computing the new value from the old one
  alone, and do I/O and other side effects before or after the call.

      Host.KV.update("webhooks:recent", [id], fn ids -> Enum.take([id | ids], 20) end)

  A value that is not JSON-shaped raises as `put/2` does. If `key`
  is still changing under `fun` after a second of retries, the update
  raises: a sign that `fun` is too slow for how often `key` is
  written.
  """
  @spec update(String.t(), value(), (value() -> value())) :: value()
  def update(key, default, fun) when is_binary(key) and is_function(fun, 1) do
    check!(default, [])

    Host.Repo.checkout(fn ->
      attempt(key, default, fun, System.monotonic_time(:millisecond) + @retry_ms)
    end)
  end

  @doc """
  Removes `key`.

  Removing a key that is not there is a no-op.
  """
  @spec delete(String.t()) :: :ok
  def delete(key) when is_binary(key) do
    Host.Repo.delete_all(from(e in Entry, where: e.key == ^key))
    :ok
  end

  @doc """
  Returns every entry whose key starts with `prefix` as a map of key
  to value, loaded in one query, e.g. `all("poller:")`.

  Use this rather than `get/2` in a loop; `keys/1` lists the keys
  alone when the values are not needed. An empty prefix returns
  everything.
  """
  @spec all(String.t()) :: %{String.t() => value()}
  def all(prefix \\ "") when is_binary(prefix) do
    prefix
    |> under()
    |> select([e], {e.key, e.value})
    |> Host.Repo.all()
    |> Map.new(fn {key, text} -> {key, decode!(key, text)} end)
  end

  @doc """
  Returns every key starting with `prefix`, sorted, without loading
  the values, e.g. `keys("poller:")`.

  `all/1` returns keys and values together. An empty prefix lists
  every key.
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
  `delete_all("poller:")`.

  An empty prefix removes every key.
  """
  @spec delete_all(String.t()) :: :ok
  def delete_all(prefix) when is_binary(prefix) do
    prefix |> under() |> Host.Repo.delete_all()
    :ok
  end

  # Compare-and-swap: fun runs with nothing locked, since SQLite has
  # one write lock for the whole agent database and holding it while
  # agent code runs would stall every other writer. The write applies
  # only if the row still holds the text that was read, compared byte
  # for byte; otherwise another write landed and the attempt starts
  # over. Inside a Host.Repo.transaction no other connection's write
  # lands between the read and the write: the transaction holds the
  # write lock already, or SQLite raises busy at the write.
  #
  # The retries are bounded by time, not by count: a writer that loses
  # the race for the write lock sleeps in SQLite's busy handler while
  # other commits land, so a fast fun on a busy key can take dozens of
  # attempts in tens of milliseconds, where a slow fun takes a few in a
  # second.
  defp attempt(key, default, fun, deadline) do
    case Host.Repo.get(Entry, key) do
      nil ->
        {count, _} =
          Host.Repo.insert_all(Entry, [%{key: key, value: JSON.encode!(default)}],
            on_conflict: :nothing,
            conflict_target: :key
          )

        if count == 1, do: default, else: retry(key, default, fun, deadline)

      %Entry{value: text} ->
        value = fun.(decode!(key, text))
        check!(value, [])

        {count, _} =
          Host.Repo.update_all(from(e in Entry, where: e.key == ^key and e.value == ^text),
            set: [value: JSON.encode!(value)]
          )

        if count == 1, do: value, else: retry(key, default, fun, deadline)
    end
  end

  defp retry(key, default, fun, deadline) do
    if System.monotonic_time(:millisecond) > deadline do
      raise "Host.KV.update/3 gave up on #{inspect(key)} after retrying for a second: " <>
              "other writes kept landing on it while your function ran. Keep the function " <>
              "fast and free of I/O: do the slow work first and pass its result in"
    end

    attempt(key, default, fun, deadline)
  end

  # The value is checked against JSON's shapes before it is encoded,
  # failing closed: JSON.encode! would write an atom or an atom key
  # as a string and a struct as its encoder chooses, and the value
  # would come back as something other than what was put. The path
  # of map keys and list indexes names where a refusal sits.
  defp check!(value, _path) when is_nil(value) or is_boolean(value) or is_number(value),
    do: :ok

  defp check!(value, path) when is_binary(value) do
    unless String.valid?(value) do
      refuse!(
        "a binary that is not UTF-8 text",
        path,
        "encode it with Base.encode64/1 and store the string"
      )
    end

    :ok
  end

  defp check!(value, path) when is_list(value), do: check_list!(value, path, 0)

  defp check!(%struct{}, path) do
    refuse!(
      "a %#{inspect(struct)}{} struct",
      path,
      "convert it to a string or a map with string keys, e.g. DateTime.to_iso8601/1"
    )
  end

  defp check!(value, path) when is_map(value) do
    Enum.each(value, fn {key, inner} ->
      unless is_binary(key) and String.valid?(key) do
        refuse!(
          "the map key #{inspect(key, limit: 5)}",
          path,
          ~s|map keys must be UTF-8 strings, e.g. %{"count" => 1} rather than %{count: 1}|
        )
      end

      check!(inner, path ++ [key])
    end)
  end

  defp check!(value, path) when is_atom(value) do
    refuse!(
      "the atom #{inspect(value)}",
      path,
      "store it as a string, e.g. #{inspect(Atom.to_string(value))}"
    )
  end

  defp check!(value, path) when is_tuple(value) do
    refuse!("the tuple #{inspect(value, limit: 5)}", path, "store a list instead")
  end

  defp check!(value, path) do
    refuse!(
      inspect(value, limit: 5),
      path,
      "funs, pids, ports and references are not data, so store what you would rebuild them from"
    )
  end

  defp check_list!([], _path, _index), do: :ok

  defp check_list!([head | tail], path, index) do
    check!(head, path ++ [index])
    check_list!(tail, path, index + 1)
  end

  defp check_list!(_tail, path, _index),
    do: refuse!("an improper list", path, "end the list with []")

  defp refuse!(what, path, hint) do
    at = if path == [], do: "", else: " at #{inspect(path)}"

    raise ArgumentError,
          "Host.KV does not store #{what}#{at}: values are JSON (nil, booleans, numbers, " <>
            "strings, lists and maps with string keys), so #{hint}"
  end

  # Only raw SQL writes a value that is not JSON text; the key names
  # the row, and delete/1 never decodes, so the row stays removable.
  defp decode!(key, text) do
    case JSON.decode(text) do
      {:ok, value} ->
        value

      {:error, _reason} ->
        raise "the value under #{inspect(key)} is not JSON: it was written outside Host.KV; " <>
                "remove it with Host.KV.delete(#{inspect(key)})"
    end
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
