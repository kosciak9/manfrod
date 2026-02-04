defmodule Manfrod.Repo.Migrations.CreateRecurringReminders do
  use Ecto.Migration

  def change do
    create table(:recurring_reminders, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :cron, :string, null: false
      add :timezone, :string, null: false, default: "Europe/Warsaw"
      add :enabled, :boolean, null: false, default: true
      add :node_id, references(:nodes, type: :binary_id, on_delete: :restrict), null: false

      timestamps()
    end

    create unique_index(:recurring_reminders, [:name])
    create index(:recurring_reminders, [:enabled])
    create index(:recurring_reminders, [:node_id])
  end
end
