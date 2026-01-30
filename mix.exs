defmodule Manfred.MixProject do
  use Mix.Project

  def project do
    [
      app: :manfred,
      version: "0.1.0",
      elixir: "~> 1.15",
      start_permanent: true,
      aliases: aliases(),
      deps: deps(),
      listeners: [Phoenix.CodeReloader]
    ]
  end

  def application do
    [
      mod: {Manfred.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  defp deps do
    [
      {:dotenvy, "~> 1.0"},
      {:phoenix, "~> 1.8.3"},
      {:phoenix_ecto, "~> 4.5"},
      {:ecto_sql, "~> 3.13"},
      {:postgrex, ">= 0.0.0"},
      {:phoenix_live_dashboard, "~> 0.8.3"},
      {:req, "~> 0.5"},
      {:jason, "~> 1.2"},
      {:bandit, "~> 1.5"},
      {:tidewave, "~> 0.5.4", only: [:dev]}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "ecto.setup"],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"]
    ]
  end
end
