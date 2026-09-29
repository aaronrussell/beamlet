defmodule Beamlet.Repo.Migrations.CreateSessions do
  use Ecto.Migration

  def change do
    create table(:sessions) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :secret_hash, :binary, null: false
      timestamps()
    end

    create unique_index(:sessions, [:secret_hash])
    create index(:sessions, [:user_id])
  end
end
