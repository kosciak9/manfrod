defmodule Manfrod.Repo.Migrations.EnableExtensions do
  use Ecto.Migration

  def up do
    execute "CREATE EXTENSION IF NOT EXISTS vector"
    execute "CREATE EXTENSION IF NOT EXISTS pg_search"
  end

  def down do
    execute "DROP EXTENSION IF EXISTS pg_search"
    execute "DROP EXTENSION IF EXISTS vector"
  end
end
