defmodule Manfrod.Repo.Migrations.CreateAuditEvents do
  use Ecto.Migration

  def change do
    create table(:audit_events, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :type, :string, null: false
      add :source, :string
      add :user_id, :bigint
      add :meta, :map, default: %{}
      add :timestamp, :utc_datetime_usec, null: false

      timestamps(updated_at: false)
    end

    create index(:audit_events, [:timestamp])
    create index(:audit_events, [:user_id])
  end
end
