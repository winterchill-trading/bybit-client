# AGENTS.md (lib/)

Library `bybit_client`.

- `Config`: `local`, `mainnet`, `testnet`, and `Config.Read_only` with no key or secret fields.
  `Public_ws.connect` and `Live_feed.connect` take a read-only config.
- `Rest` covers the endpoints of `bybit-protocol`; signed requests use the `X-BAPI-*` headers and
  `Api_error` separates venue rejections from transport failures.
- `Ws_stream` is the shared socket core (JSON ping, optional auth, topics replayed on reconnect).
  `Public_ws` and `Private_ws` are the two streams.
- `Frame_scan` is the zero-allocation scanner for hot public frames. `Live_feed` and `Normalizer`
  build on it; `Raw_normalizer` adapts it to `Market_data.Normalizer.S`.
- `Venue` is the `Mm_core.Venue.S` adapter.
- Build: `dune build --root .. @bybit-client/all` from the repository root.
