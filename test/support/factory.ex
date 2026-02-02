defmodule Manfrod.Factory do
  @moduledoc """
  Test factories for Manfrod schemas.
  """

  alias Manfrod.Repo
  alias Manfrod.Memory.{Conversation, Message, Node, Link}

  def fake_embedding(seed \\ "test") do
    :rand.seed(:exsss, {:erlang.phash2(seed), 0, 0})
    for _ <- 1..1024, do: :rand.uniform() - 0.5
  end

  # Messages

  def message_attrs(attrs \\ %{}) do
    Map.merge(
      %{
        role: "user",
        content: "Test message #{System.unique_integer([:positive])}",
        received_at: DateTime.utc_now() |> DateTime.truncate(:second)
      },
      attrs
    )
  end

  def insert_message!(attrs \\ %{}) do
    %Message{}
    |> Message.changeset(message_attrs(attrs))
    |> Repo.insert!()
  end

  # Conversations

  def conversation_attrs(attrs \\ %{}) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Map.merge(
      %{
        started_at: DateTime.add(now, -3600, :second),
        ended_at: now,
        summary: "Test conversation #{System.unique_integer([:positive])}"
      },
      attrs
    )
  end

  def insert_conversation!(attrs \\ %{}) do
    %Conversation{}
    |> Conversation.changeset(conversation_attrs(attrs))
    |> Repo.insert!()
  end

  # Nodes

  def node_attrs(attrs \\ %{}) do
    content = Map.get(attrs, :content, "Test node #{System.unique_integer([:positive])}")

    Map.merge(
      %{content: content, embedding: fake_embedding(content)},
      attrs
    )
  end

  def insert_node!(attrs \\ %{}) do
    %Node{}
    |> Node.changeset(node_attrs(attrs))
    |> Repo.insert!()
  end

  # Links

  def insert_link!(node_a, node_b) do
    %Link{}
    |> Link.changeset(%{node_a_id: node_a.id, node_b_id: node_b.id})
    |> Repo.insert!()
  end
end
