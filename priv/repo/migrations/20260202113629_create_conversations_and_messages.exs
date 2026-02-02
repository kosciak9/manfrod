defmodule Manfrod.Repo.Migrations.CreateConversationsAndMessages do
  use Ecto.Migration

  def change do
    # Conversations - closed conversation sessions with summaries
    create table(:conversations, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :started_at, :utc_datetime, null: false
      add :ended_at, :utc_datetime, null: false
      add :summary, :text, null: false

      timestamps()
    end

    # Messages - individual exchanges, null conversation_id = active/pending
    create table(:messages, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :conversation_id,
          references(:conversations, type: :binary_id, on_delete: :restrict)

      add :role, :string, null: false
      add :content, :text, null: false
      add :received_at, :utc_datetime, null: false

      timestamps()
    end

    create index(:messages, [:conversation_id])

    # Partial index for efficiently finding pending messages
    create index(:messages, [:received_at],
             where: "conversation_id IS NULL",
             name: :messages_pending_idx
           )
  end
end
