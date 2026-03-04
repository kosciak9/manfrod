defmodule Manfrod.Repo.Migrations.DropTasksAndDeploymentState do
  use Ecto.Migration

  def change do
    drop_if_exists table(:tasks)
    drop_if_exists table(:deployment_state)
  end
end
