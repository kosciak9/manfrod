defmodule Manfrod.Repo.Migrations.FixSoulNodeTimestamp do
  use Ecto.Migration

  def up do
    # The soul node (containing "I am Manfrod") should be the earliest node
    # so get_soul/0 reliably identifies it. The original seed had a timestamp
    # collision bug where all nodes got the same inserted_at second.
    # Fix: set the soul node's inserted_at 60 seconds before the others.
    execute("""
    UPDATE nodes
    SET inserted_at = inserted_at - interval '60 seconds'
    WHERE content LIKE 'I am Manfrod, a personal AI assistant%'
    AND inserted_at = (
      SELECT MIN(inserted_at) FROM nodes
    )
    """)
  end

  def down do
    # Reverse the timestamp shift
    execute("""
    UPDATE nodes
    SET inserted_at = inserted_at + interval '60 seconds'
    WHERE content LIKE 'I am Manfrod, a personal AI assistant%'
    """)
  end
end
