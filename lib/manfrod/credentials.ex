defmodule Manfrod.Credentials do
  @moduledoc """
  Manages encrypted credential storage.

  Credentials are stored encrypted in the database using Cloak.
  Only one set of credentials exists (single-user system).
  """

  alias Manfrod.Credentials.Credential
  alias Manfrod.Repo

  @doc """
  Returns whether credentials have been configured.
  """
  def configured? do
    Repo.exists?(Credential)
  end

  @doc """
  Get the current credentials, or nil if not configured.
  """
  def get do
    Repo.one(Credential)
  end

  @doc """
  Get a specific credential value by key.
  """
  def get_value(key) when is_atom(key) do
    case get() do
      nil -> nil
      cred -> Map.get(cred, key)
    end
  end

  @doc """
  Create or update credentials.

  If credentials already exist, they are updated.
  If not, new credentials are created.
  """
  def save(attrs) when is_map(attrs) do
    case get() do
      nil ->
        %Credential{}
        |> Credential.changeset(attrs)
        |> Repo.insert()

      existing ->
        existing
        |> Credential.changeset(attrs)
        |> Repo.update()
    end
  end
end
