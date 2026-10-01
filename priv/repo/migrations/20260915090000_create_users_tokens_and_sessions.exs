defmodule Beamlet.Repo.Migrations.CreateUsersTokensAndSessions do
  use Ecto.Migration

  def change do
    create table(:users, primary_key: false) do
      add :id, :integer, primary_key: true, check: %{name: "one_user", expr: "id = 1"}
      add :email, :string, null: false
      add :password_hash, :string, null: false
      timestamps()
    end

    create table(:tokens) do
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
    create unique_index(:tokens, [:name])

    create table(:sessions) do
      add :secret_hash, :binary, null: false
      timestamps()
    end

    create unique_index(:sessions, [:secret_hash])
  end
end
