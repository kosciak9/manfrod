defmodule Manfrod.Repo.Migrations.RecreateNodesBm25Index do
  use Ecto.Migration

  @doc """
  Recreates the BM25 index after user_id column was removed from nodes table.
  The original index included user_id which no longer exists.
  """
  def up do
    # Drop existing index if it somehow still exists
    execute "DROP INDEX IF EXISTS nodes_bm25_idx"

    # Recreate BM25 index without user_id
    execute """
    CREATE INDEX nodes_bm25_idx ON nodes
    USING bm25 (id, content)
    WITH (key_field='id')
    """
  end

  def down do
    execute "DROP INDEX IF EXISTS nodes_bm25_idx"
  end
end
