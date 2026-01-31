defmodule Manfrod.Memory.Link do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "links" do
    belongs_to :node_a, Manfrod.Memory.Node
    belongs_to :node_b, Manfrod.Memory.Node

    timestamps(updated_at: false)
  end

  @doc """
  Creates a changeset for a link.
  Enforces node_a_id < node_b_id to ensure undirected edge uniqueness.
  """
  def changeset(link, attrs) do
    link
    |> cast(attrs, [:node_a_id, :node_b_id])
    |> validate_required([:node_a_id, :node_b_id])
    |> normalize_node_order()
    |> unique_constraint([:node_a_id, :node_b_id])
  end

  defp normalize_node_order(changeset) do
    case {get_field(changeset, :node_a_id), get_field(changeset, :node_b_id)} do
      {a, b} when is_binary(a) and is_binary(b) and a > b ->
        changeset
        |> put_change(:node_a_id, b)
        |> put_change(:node_b_id, a)

      _ ->
        changeset
    end
  end
end
