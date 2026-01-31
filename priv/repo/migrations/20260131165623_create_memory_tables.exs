defmodule Manfrod.Repo.Migrations.CreateMemoryTables do
  use Ecto.Migration

  def change do
    # Nodes - slipbox knowledge units
    create table(:nodes, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :content, :text, null: false
      add :embedding, :vector, size: 1024
      add :user_id, :bigint, null: false

      timestamps()
    end

    create index(:nodes, [:user_id])

    # Links - undirected edges between nodes
    create table(:links, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :node_a_id, references(:nodes, type: :binary_id, on_delete: :delete_all), null: false
      add :node_b_id, references(:nodes, type: :binary_id, on_delete: :delete_all), null: false

      timestamps(updated_at: false)
    end

    create index(:links, [:node_a_id])
    create index(:links, [:node_b_id])
    create unique_index(:links, [:node_a_id, :node_b_id])
  end
end
