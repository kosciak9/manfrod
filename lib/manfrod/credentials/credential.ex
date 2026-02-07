defmodule Manfrod.Credentials.Credential do
  @moduledoc """
  Schema for encrypted credential storage.

  Stores GitHub and Gmail credentials encrypted at rest using Cloak.
  Only one row should exist (single-user system).
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "credentials" do
    field :github_token, Manfrod.Encrypted.Binary
    field :gmail_email, Manfrod.Encrypted.Binary
    field :gmail_app_password, Manfrod.Encrypted.Binary

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(credential, attrs) do
    credential
    |> cast(attrs, [:github_token, :gmail_email, :gmail_app_password])
    |> validate_required([:github_token, :gmail_email, :gmail_app_password])
  end
end
