Postgrex.Types.define(
  Manfrod.PostgrexTypes,
  Pgvector.extensions() ++ Paradex.extensions() ++ Ecto.Adapters.Postgres.extensions(),
  []
)
