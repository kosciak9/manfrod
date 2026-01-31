defmodule Manfrod.Repo.Migrations.AddMemoryIndexes do
  use Ecto.Migration

  def up do
    # HNSW index for vector similarity search
    execute """
    CREATE INDEX nodes_embedding_idx ON nodes
    USING hnsw (embedding vector_cosine_ops)
    """

    # BM25 index for full-text search via ParadeDB
    execute """
    CREATE INDEX nodes_bm25_idx ON nodes
    USING bm25 (id, content, user_id)
    WITH (key_field='id')
    """
  end

  def down do
    execute "DROP INDEX IF EXISTS nodes_bm25_idx"
    execute "DROP INDEX IF EXISTS nodes_embedding_idx"
  end
end
