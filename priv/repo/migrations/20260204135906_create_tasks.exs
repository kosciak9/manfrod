defmodule Manfrod.Repo.Migrations.CreateTasks do
  use Ecto.Migration

  def change do
    create table(:tasks, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :status, :string, null: false, default: "todo"
      add :assignee, :string, null: false
      add :output, :text
      add :completed_at, :utc_datetime

      add :note_id, references(:nodes, type: :binary_id, on_delete: :delete_all), null: false

      add :conversation_id, references(:conversations, type: :binary_id, on_delete: :nilify_all)

      timestamps()
    end

    create index(:tasks, [:status, :assignee])
    create index(:tasks, [:note_id])
    create index(:tasks, [:conversation_id])
  end
end
