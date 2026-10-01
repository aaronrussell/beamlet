defmodule Beamlet.Repo.Migrations.CreateUsersAndTokens do
  use Ecto.Migration

  def change do
    create table(:users) do
      add :name, :string, null: false
      add :password_hash, :string
      timestamps()
    end

    create unique_index(:users, [:name])

    create table(:tokens) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :kind, :string, null: false
      add :name, :string
      add :client, :string
      add :policy, :string, null: false
      add :secret_hash, :binary, null: false
      add :expires_at, :utc_datetime
      add :refresh_hash, :binary
      add :refresh_expires_at, :utc_datetime
      timestamps()
    end

    create unique_index(:tokens, [:secret_hash])
    create unique_index(:tokens, [:refresh_hash])
    create unique_index(:tokens, [:user_id, :name])
  end
end
