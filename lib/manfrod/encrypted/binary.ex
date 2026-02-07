defmodule Manfrod.Encrypted.Binary do
  @moduledoc """
  Encrypted binary field type for Ecto schemas.

  Automatically encrypts data on write and decrypts on read using
  the application's Vault.
  """
  use Cloak.Ecto.Binary, vault: Manfrod.Vault
end
