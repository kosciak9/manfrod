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
  - Only extract long-term valuable info (facts about user, decisions, preferences, context)
  - Links connect related nodes (0-indexed)
  - Return {"nodes": [], "links": []} if nothing worth remembering
  - The conversation may contain multiple exchanges - extract from all of them

  Conversation:
  """

  @doc """
  Fire-and-forget batch extraction for multiple exchanges.
  Called on conversation flush (5-min debounce).
  """
  def extract_batch_async(exchanges, user_id) when is_list(exchanges) do
    Task.start(fn -> extract_and_store(exchanges, user_id) end)
    :ok
  end

  @doc "Synchronous batch extraction."
  def extract_and_store(exchanges, user_id) when is_list(exchanges) do
    conversation = format_exchanges(exchanges)
    do_extract_and_store(conversation, user_id)
  end

  defp format_exchanges(exchanges) do
    exchanges
    |> Enum.with_index(1)
    |> Enum.map_join("\n\n", fn {{user, assistant}, i} ->
      "Exchange #{i}:\nUser: #{user}\nAssistant: #{assistant}"
    end)
  end

  defp do_extract_and_store(conversation, user_id) do
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
