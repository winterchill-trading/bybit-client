# AGENTS.md (bin/)

`bybit-cli`: `orderbook`, `tickers`, `watch`, `feed` and `rebuild-norm` (rebuilds event logs from
recorded raw minute files). The README lists the flags.

- The REST root defaults to the local simulator at `http://localhost:3400`; pass the URL flag to
  point elsewhere.
- Do not place orders from the CLI against mainnet while testing.
- Build: `dune build --root .. @bybit-client/all` from the repository root.
