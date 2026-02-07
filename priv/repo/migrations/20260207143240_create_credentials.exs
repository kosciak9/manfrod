defmodule Manfrod.Repo.Migrations.CreateCredentials do
  use Ecto.Migration

  def change do
    create table(:credentials, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :github_token, :binary
      add :gmail_email, :binary
      add :gmail_app_password, :binary

      timestamps(type: :utc_datetime)
    end
  end
end
