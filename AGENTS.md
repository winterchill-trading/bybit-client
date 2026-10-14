# AGENTS.md

## Purpose

Async client for the Bybit v5 HTTP and websocket API (category `linear`): REST, public and
private websockets, a normalized `Live_feed` for market data, and a `Mm_core.Venue.S` adapter so
the market maker runs on Bybit or on `bybit-sim`. A read-only configuration has no credential
fields, so market-data code cannot sign.

## Layout

| Path | Holds |
| --- | --- |
| `lib/` | Library `bybit_client`: `Config`, `Rest`, `Public_ws`, `Private_ws`, `Ws_stream`, `Local_book`, `Live_feed`, `Frame_scan`, `Raw_normalizer`, `Id_map`, `Venue` (see `lib/AGENTS.md`) |
| `bin/` | `bybit-cli`: `orderbook`, `tickers`, `watch`, `feed`, `rebuild-norm` (see `bin/AGENTS.md`) |
| `bench/` | Decode-plus-normalize benchmark and the feed delivery benchmark (see `bench/AGENTS.md`) |
| `test/` | Expect tests, allocation bounds, fixtures, loopback server, `blast/` load helper (see `test/AGENTS.md`) |
| `.github/` | CI workflow (see `.github/AGENTS.md`) |
| `dune-project`, `bybit-client.opam` | Package metadata; the `.opam` file is generated from `dune-project` |

## Build, test, docs

Run from this directory. The workspace root `..` holds the sibling checkouts and the shared
`dune-workspace`.

```sh
opam exec --switch 5.2.0+ox -- dune build --root .. @bybit-client/all
opam exec --switch 5.2.0+ox -- dune build --root .. @bybit-client/runtest
DUNE_BUILD_DIR=_build-bybit-client opam exec --switch 5.2.0+ox -- dune build --root .. @bybit-client/all
```

The last line is for parallel work: a private build directory avoids the lock shared with
other repositories in the workspace.

Run against the simulator: in `../bybit-sim`, start `dune exec bybit-sim -- -port 3400`, then
here `dune exec bybit-cli -- orderbook BTCUSDT`. Testnet and mainnet are selected in `Config`
(see the README).

Standalone (outside the workspace), the `Build` section of `README.md` lists the opam pins and
install commands. `bybit-sim` and `exchange-core-engine` are test-only.

## Conventions

- Formatting: `dune build --root .. @bybit-client/fmt --auto-promote`, run after the tests pass.
  Never `dune fmt` at the workspace root; it reformats every sibling repository.
- Every module has an `.mli`. Use `open! Core`, labelled arguments and `ppx_jane`.
- `Public_ws` and `Live_feed` take `Config.Read_only`. Do not give market-data code a path to a
  credential.
- Frames are decoded once (`Frame_scan`, the zero-allocation path). Keep new work on that path,
  and keep its allocation bounds in `test/` current.
- Allocation bounds are tolerant of per-platform word counts; the tolerance and its reason are
  in the test. Explain any change in the commit message.
- Add a short comment at any non-obvious choice, such as a resync rule.
- Document every public value in its `.mli` with odoc comments.

## Dependencies and dependents

- Depends on: `venue-net`, `bybit-protocol`, `exchange-core`, `mm-core`, `market-data`.
- Test-only: `bybit-sim`, `exchange-core-engine`.
- Used by: `market-maker`, `market-recorder`.
- CI pin order: `fixed-decimal`, `exchange-core`, `parquet`, `market-data`, `order-book`,
  `exchange-core-engine`, `venue-net`, `bybit-protocol`, `mm-core`, `bybit-sim`.

## CI

`.github/workflows/ci.yml` runs the `ox-setup` action with the pins above (its opam switch is
cached between runs), then `dune build` and `dune test`. The `obj-magic` job calls the shared
reusable workflow. To check a run: `gh run list --limit 1`, then at most one
`gh run watch <id> --exit-status`. Do not poll in a loop.

## Pitfalls

- Bybit `orderbook.N` deltas before the first snapshot are dropped; a sequence gap means
  resubscribe. A socket reconnect resets books and tickers.
- The private stream waits for the auth acknowledgement before it subscribes.
- By-id order lookup on linear needs `symbol` or `settleCoin`.
- `Id_map` maps Bybit string ids to `int64`; negative ids are stable only per `Venue.t`.
- `Fill.closed_pnl` is `None`: Bybit reports closed PnL per order and position. `realized_pnl`
  is after fees and funding.
- `Live_feed.feed_with_gaps` drops trades inside a gap; book and funding state return with the
  next snapshot.
- `Config` redacts the secret in sexps. Keep it that way in new config fields.
- Exception sexps embed the source path; keep them out of expect output.
- `dune promote` overwrites test edits made after the failing run. Promote only after reading
  the diff.

## Where to read more

- `README.md` (API by module, reconnect frame loss, benchmarks, `UNVERIFIED` list).
- `../specs/repos/bybit-client.md` for status, known gaps and the CI pin order.
- `../specs/repos/bybit-protocol.md` for the wire types.
- Skills in `../oxcaml-claude-skills/skills/`: `async-http-websocket`, `oxcaml-performance`,
  `janestreet-ocaml-style`.
- `../oxcaml-claude-skills/AGENTS.md`: the workspace-wide guide.
- `../oxcaml-claude-skills/GOTCHAS.md`: the dated log these pitfalls come from.

## Never do

- Run `opam install`, `opam upgrade` or `opam pin` on the shared `5.2.0+ox` switch without a
  dry run first: `opam install --switch 5.2.0+ox --dry-run <pkg>`. Abort if the plan touches
  `ocaml-variants`, `core`, `base`, `async` or `ppx_jane`.
- Place orders on Bybit mainnet from a test or an experiment. Use the simulator or recorded frames.
- Publish, tag or release a version from this repository without the maintainers asking.
- Commit credentials or print secrets. Keys come from the environment.
- Poll CI in a loop.
