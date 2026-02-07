defmodule Manfrod.Vault do
  @moduledoc """
  Encryption vault for sensitive data.

  Uses AES-256-GCM for encrypting credentials stored in the database.
  The encryption key is derived from the CLOAK_KEY environment variable,
  which must be a base64-encoded 32-byte key.

  ## Key generation

      :crypto.strong_rand_bytes(32) |> Base.encode64()
  """
  use Cloak.Vault, otp_app: :manfrod

  @impl GenServer
  def init(config) do
    config =
      Keyword.put(config, :ciphers,
        default:
          {Cloak.Ciphers.AES.GCM, tag: "AES.GCM.V1", key: decode_env!("CLOAK_KEY"), iv_length: 12}
      )

    {:ok, config}
  end

  defp decode_env!(var) do
    case System.get_env(var) do
      nil ->
        # Generate a random key if not configured (dev/first run)
        :crypto.strong_rand_bytes(32)

      value ->
        Base.decode64!(value)
    end
  end
end
