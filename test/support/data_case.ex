defmodule Manfrod.DataCase do
  @moduledoc """
  Test case for tests that require database access.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      alias Manfrod.Repo
      import Ecto.Query
      import Manfrod.DataCase
      import Manfrod.Factory
    end
  end

  setup tags do
    Manfrod.DataCase.setup_sandbox(tags)
    :ok
  end

  def setup_sandbox(_tags) do
    # Use shared mode so Persister and other processes can access DB
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Manfrod.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Manfrod.Repo, {:shared, self()})
  end
end
