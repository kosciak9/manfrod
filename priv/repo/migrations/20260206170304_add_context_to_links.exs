defmodule Manfrod.Repo.Migrations.AddContextToLinks do
  use Ecto.Migration

  def change do
    alter table(:links) do
      add :context, :text
    end
  end
end
