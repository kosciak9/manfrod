defmodule Manfrod.Repo.Migrations.AddObanJobsTable do
  use Ecto.Migration

  def up do
    # Clear existing data - fresh start
    execute("TRUNCATE nodes, links, conversations, messages, audit_events CASCADE")

    Oban.Migration.up(version: 12)
  end

  def down do
    Oban.Migration.down(version: 1)
  end
end
