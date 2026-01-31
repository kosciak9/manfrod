defmodule Manfrod.Memory.Node do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "nodes" do
    field :content, :string
    field :embedding, Pgvector.Ecto.Vector
    field :user_id, :integer

    timestamps()
  end

  def changeset(node, attrs) do
    node
    |> cast(attrs, [:content, :embedding, :user_id])
    |> validate_required([:content, :user_id])
  end
end
