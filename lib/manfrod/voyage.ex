defmodule Manfrod.Voyage do
  @moduledoc """
  Voyage AI client for embeddings and reranking.

  Uses voyage-4-lite for cost-effective embeddings with good quality.
  Uses rerank-2.5-lite for reranking search results.
  """

  @base_url "https://api.voyageai.com/v1"
  @embed_model "voyage-4-lite"
  @rerank_model "rerank-2.5-lite"

  @doc """
  Generate embeddings for texts. Returns {:ok, [embedding, ...]} or {:error, reason}.
  Options: :api_key, :input_type ("document" or "query")
  """
  def embed(texts, opts \\ []) when is_list(texts) do
    api_key = opts[:api_key] || Application.get_env(:manfrod, :voyage_api_key)

    body = %{
      input: texts,
      model: @embed_model,
      input_type: opts[:input_type] || "document"
    }

    case Req.post("#{@base_url}/embeddings",
           json: body,
           headers: [{"authorization", "Bearer #{api_key}"}]
         ) do
      {:ok, %{status: 200, body: %{"data" => data}}} ->
        embeddings = data |> Enum.sort_by(& &1["index"]) |> Enum.map(& &1["embedding"])
        {:ok, embeddings}

      {:ok, %{status: status, body: body}} ->
        {:error, {status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Embed a single query text (uses input_type: query for asymmetric retrieval)."
  def embed_query(text) do
    case embed([text], input_type: "query") do
      {:ok, [embedding]} -> {:ok, embedding}
      error -> error
    end
  end

  @doc """
  Rerank documents by relevance to a query.

  Takes a query and list of documents, returns documents sorted by relevance
  with scores. Uses Voyage's rerank-2.5-lite model.

  ## Arguments

    * `query` - The search query string
    * `documents` - List of document strings to rerank
    * `opts` - Options:
      * `:top_k` - Return only top K results (default: all)
      * `:api_key` - Override API key

  ## Returns

    * `{:ok, [%{index: 0, relevance_score: 0.95}, ...]}` - Sorted by score descending
    * `{:error, reason}` - On failure

  ## Example

      {:ok, results} = Voyage.rerank("elixir deployment", ["doc about elixir", "doc about python"])
      # => {:ok, [%{index: 0, relevance_score: 0.85}, %{index: 1, relevance_score: 0.12}]}
  """
  def rerank(query, documents, opts \\ []) when is_binary(query) and is_list(documents) do
    api_key = opts[:api_key] || Application.get_env(:manfrod, :voyage_api_key)
    top_k = opts[:top_k]

    body =
      %{
        query: query,
        documents: documents,
        model: @rerank_model
      }
      |> maybe_add_top_k(top_k)

    case Req.post("#{@base_url}/rerank",
           json: body,
           headers: [{"authorization", "Bearer #{api_key}"}]
         ) do
      {:ok, %{status: 200, body: %{"data" => data}}} ->
        # Data comes as list of %{"index" => i, "relevance_score" => score}
        # Already sorted by relevance_score descending
        results =
          Enum.map(data, fn item ->
            %{index: item["index"], relevance_score: item["relevance_score"]}
          end)

        {:ok, results}

      {:ok, %{status: status, body: body}} ->
        {:error, {status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_add_top_k(body, nil), do: body
  defp maybe_add_top_k(body, top_k) when is_integer(top_k), do: Map.put(body, :top_k, top_k)
end
