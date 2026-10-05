defmodule Beamlet.Repo.Migrations.CreateRoutes do
  use Ecto.Migration

  def change do
    create table(:routes) do
      add :kind, :string, null: false
      add :verb, :string, null: false
      add :path, :string, null: false
      add :module, :string, null: false
      add :action, :string
      add :principal, :map, null: false
      timestamps(updated_at: false)
    end

    create unique_index(:routes, [:verb, :path])
  end
end
