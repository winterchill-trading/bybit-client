# AGENTS.md (test/)

Tests for `bybit_client`. `dune test` runs without network access.

- `fixtures/` holds 20 seconds of BTCUSDT mainnet frames per stream. Fixtures are data; do not
  edit them by hand.
- `loopback.ml` serves frames over a local websocket; `test_live_feed.ml`, `_gaps.ml`, `_stats.ml`
  and `_words.ml` run `Live_feed` against it, including a malformed frame counted in `stats`
  and a reconnect on a synthetic clock.
- `blast/` is a websocket server writing pre-encoded frames for the words-per-frame test and the
  feed benchmark.
- Allocation tests bound the live path per frame. Explain changes in the commit message.
- Run: `dune build --root .. @bybit-client/runtest` from the repository root.
- Promote expect output with `dune promote` only after reading the diff.
