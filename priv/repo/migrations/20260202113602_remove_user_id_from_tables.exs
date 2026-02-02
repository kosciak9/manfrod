defmodule Manfrod.Repo.Migrations.RemoveUserIdFromTables do
  use Ecto.Migration

  def change do
    # Drop indexes first
    drop index(:nodes, [:user_id])
    drop index(:audit_events, [:user_id])

    # Remove user_id columns
    alter table(:nodes) do
      remove :user_id, :bigint, null: false
    end

    alter table(:audit_events) do
      remove :user_id, :bigint
    end
  end
end
