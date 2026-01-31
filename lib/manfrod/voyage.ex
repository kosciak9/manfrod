defmodule Manfrod.Voyage do
  @moduledoc "Voyage AI embeddings client."

  @base_url "https://api.voyageai.com/v1"
  @model "voyage-3"

  @doc """
  Generate embeddings for texts. Returns {:ok, [embedding, ...]} or {:error, reason}.
  Options: :api_key, :input_type ("document" or "query")
  """
  def embed(texts, opts \\ []) when is_list(texts) do
    api_key = opts[:api_key] || Application.get_env(:manfrod, :voyage_api_key)

    body = %{
      input: texts,
      model: @model,
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
end
