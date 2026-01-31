defmodule Manfrod.Memory.Extractor do
  @moduledoc """
  Extracts knowledge nodes and links from conversations via LLM.
  """

  require Logger
  alias Manfrod.{Memory, Voyage}

  @base_url "https://opencode.ai/zen/v1"
  @model_id "kimi-k2.5-free"

  @extraction_prompt """
  Extract knowledge worth remembering from this conversation.
  Return JSON: {"nodes": ["fact 1", "fact 2"], "links": [[0, 1]]}

  Rules:
  - Each node = one atomic fact (1-2 sentences max)
  - Only extract long-term valuable info
  - Links connect related nodes (0-indexed)
  - Return {"nodes": [], "links": []} if nothing worth remembering

  Conversation:
  """

  @doc "Fire-and-forget extraction. Returns :ok immediately."
  def extract_async(user_content, assistant_content, user_id) do
    Task.start(fn -> extract_and_store(user_content, assistant_content, user_id) end)
    :ok
  end

  @doc "Synchronous extraction for testing."
  def extract_and_store(user_content, assistant_content, user_id) do
    conversation = "User: #{user_content}\nAssistant: #{assistant_content}"

    with {:ok, %{"nodes" => [_ | _] = texts, "links" => links}} <- call_llm(conversation),
         {:ok, embeddings} <- Voyage.embed(texts) do
      node_ids =
        texts
        |> Enum.zip(embeddings)
        |> Enum.map(fn {content, embedding} ->
          {:ok, node} =
            Memory.create_node(%{content: content, embedding: embedding, user_id: user_id})

          node.id
        end)

      for [a, b] <- links, a < length(node_ids), b < length(node_ids) do
        Memory.create_link(Enum.at(node_ids, a), Enum.at(node_ids, b))
      end

      Logger.info("Extracted #{length(node_ids)} nodes, #{length(links)} links")
      {:ok, node_ids}
    else
      {:ok, %{"nodes" => []}} ->
        {:ok, []}

      {:error, reason} = err ->
        Logger.error("Extraction failed: #{inspect(reason)}")
        err
    end
  end

  defp call_llm(conversation) do
    api_key = Application.get_env(:manfrod, :zen_api_key)
    prompt = @extraction_prompt <> conversation
    context = ReqLLM.Context.new([ReqLLM.Context.user(prompt)])
    model = %{id: @model_id, provider: :openai}

    case ReqLLM.generate_text(model, context, base_url: @base_url, api_key: api_key) do
      {:ok, response} -> parse_json(ReqLLM.Response.text(response))
      error -> error
    end
  end

  defp parse_json(text) do
    # Strip markdown code fences if present
    json =
      case Regex.run(~r/```(?:json)?\s*(.*?)\s*```/s, text) do
        [_, inner] -> inner
        nil -> text
      end

    case Jason.decode(String.trim(json)) do
      {:ok, %{"nodes" => nodes, "links" => links}} when is_list(nodes) and is_list(links) ->
        {:ok, %{"nodes" => nodes, "links" => links}}

      {:ok, %{"nodes" => nodes}} when is_list(nodes) ->
        {:ok, %{"nodes" => nodes, "links" => []}}

      _ ->
        {:error, :invalid_json}
    end
  end
end
