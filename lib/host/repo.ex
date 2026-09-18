defmodule Host.Repo do
  @moduledoc """
  The agent database: SQLite, shared by every module on your beamlet.

  Define an `Ecto.Schema` module for a table, then read and write it
  with the standard Ecto repo API:

      defmodule Shopping.Item do
        @moduledoc "An item on the shopping list."
        use Ecto.Schema
        import Ecto.Changeset

        schema "shopping_items" do
          field :name, :string
          field :done, :boolean, default: false
          timestamps()
        end

        @doc "Casts name and done; name is required."
        def changeset(item, attrs) do
          item |> cast(attrs, [:name, :done]) |> validate_required([:name])
        end
      end

      Host.Repo.insert(Shopping.Item.changeset(%Shopping.Item{}, %{name: "milk"}))
      Host.Repo.all(from i in Shopping.Item, where: not i.done, order_by: i.name)

  Tables are created by migrations, which `Host.Migrator` runs
  against this database; small state that needs no table of its own,
  a cursor or a last-run time, goes in `Host.KV`. Every function
  here is Ecto's own `Ecto.Repo` API: `all`, `get`, `one`, `insert`,
  `update`, `delete`, `insert_all`, `update_all`, `transaction` and
  the rest.

  Ecto's query builders (`from`, `where`, `order_by`, `limit` and
  the rest) are macros: put `import Ecto.Query` at the top of any
  eval or module that queries. A `:map` field is stored as JSON, so
  its keys come back as strings. Raw SQL through `query/2` runs one
  statement per call, since SQLite silently ignores anything after
  the first, and stays inside this database file: `ATTACH DATABASE`
  is refused on every connection.
  """

  use Ecto.Repo, otp_app: :beamlet, adapter: Ecto.Adapters.SQLite3

  @db_file "agent.db"

  @impl true
  def init(_context, config) do
    db_file = Path.join(Beamlet.Config.db_dir(), @db_file)

    config =
      config
      |> Keyword.put(:database, db_file)
      |> Keyword.put(:journal_mode, :wal)
      |> Keyword.put(:after_connect, {Beamlet.SQLiteAuthorizer, :install, [[:attach, :detach]]})

    {:ok, config}
  end
end
