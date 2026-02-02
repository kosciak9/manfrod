defmodule Manfrod.Repo.Migrations.AddDeploymentState do
  use Ecto.Migration

  def change do
    create table(:deployment_state, primary_key: false) do
      add :key, :string, primary_key: true
      add :value, :string
      add :updated_at, :utc_datetime
    end
  end
end
