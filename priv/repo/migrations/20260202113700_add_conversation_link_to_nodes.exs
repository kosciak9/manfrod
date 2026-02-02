defmodule Manfrod.Repo.Migrations.AddConversationLinkToNodes do
  use Ecto.Migration

  def change do
    alter table(:nodes) do
      # Link to source conversation (provenance)
      add :conversation_id,
          references(:conversations, type: :binary_id, on_delete: :restrict)

      # Slipbox flag: null = unprocessed (in slipbox), set = processed by retrospection
      add :processed_at, :utc_datetime
    end

    create index(:nodes, [:conversation_id])

    # Partial index for efficiently finding slipbox items
    create index(:nodes, [:inserted_at],
             where: "processed_at IS NULL",
             name: :nodes_slipbox_idx
           )
  end
end
