# bybit-client

Async client for the Bybit v5 HTTP and websocket API (category `linear`, USDT
perpetuals), plus an `Mm_core.Venue.S` adapter so the market maker runs on Bybit.

Built with [OxCaml](https://oxcaml.org) and the Jane Street library stack (Core, Async),
on top of the wire types in
[bybit-protocol](https://github.com/winterchill-trading/bybit-protocol) and the
venue-independent transport in
[venue-net](https://github.com/winterchill-trading/venue-net). It targets the local
simulator ([bybit-sim](https://github.com/winterchill-trading/bybit-sim)) and the real
Bybit API (mainnet and testnet). It is the Bybit counterpart of
[hl-client](https://github.com/winterchill-trading/hl-client).

## Build

```sh
opam switch create 5.2.0+ox --repos ox=git+https://github.com/oxcaml/opam-repository.git,default
for p in fixed-decimal exchange-core parquet market-data order-book; do
  opam pin add -n -y $p https://github.com/winterchill-trading/$p.git
done
opam pin add -n -y exchange-core-engine https://github.com/winterchill-trading/exchange-core.git
for p in venue-net bybit-protocol mm-core bybit-sim; do
  opam pin add -n -y $p https://github.com/winterchill-trading/$p.git
done
opam install . --deps-only --with-test
dune build && dune test
```

Inside a dune workspace that also contains the sibling repos, dune uses their sources and
the pins are not needed. `bybit-sim` and `exchange-core-engine` are test dependencies
only.

`https://` and `wss://` need `async_ssl` (OpenSSL 3). On macOS with Homebrew's
`openssl@4`, see the OpenSSL notes in
[hl-client](https://github.com/winterchill-trading/hl-client#macos-and-openssl).

CI installs the pinned siblings and the opam dependencies through the shared
[ox-setup](https://github.com/winterchill-trading/infra/blob/main/docs/ci.md) action, which
caches the built opam switch between runs.

## Quick start

```ocaml
open! Core
open Async
open Bybit_protocol

let main () =
  let config = Bybit_client.Config.local ~api_key:"mm" () in   (* http://localhost:3400 *)
  let btc = Symbol.of_string "BTCUSDT" in
  let%bind book = Bybit_client.Rest.orderbook ~limit:5 config btc in
  print_s [%sexp (Or_error.ok_exn book : Orderbook.t)];
  let%bind ws = Bybit_client.Public_ws.connect config >>| ok_exn in
  let%bind () = Bybit_client.Public_ws.subscribe ws (Orderbook { depth = 50; symbol = btc }) in
  Pipe.iter_without_pushback (Bybit_client.Public_ws.messages ws) ~f:(fun message ->
    print_s [%sexp (message : Ws_message.t)])
```

## API

All modules live under `Bybit_client`. Every network call returns `_ Or_error.t
Deferred.t`.

### `Config`

```ocaml
type t =
  { base_url : Uri.t; ws_public_url : Uri.t; ws_private_url : Uri.t
  ; api_key : string option; api_secret : string option; recv_window : int }

val create  : ?ws_public_url:Uri.t -> ?ws_private_url:Uri.t -> ?api_key:string
  -> ?api_secret:string -> ?recv_window:int -> base_url:Uri.t -> unit -> t
val local   : ?port:int -> ?api_key:string -> ?api_secret:string -> unit -> t  (* http://localhost:3400 *)
val mainnet : ?api_key:string -> ?api_secret:string -> unit -> t   (* api.bybit.com, stream.bybit.com *)
val testnet : ?api_key:string -> ?api_secret:string -> unit -> t   (* api-testnet / stream-testnet *)

module Read_only : sig
  type t                                  (* base_url and ws_public_url, nothing else *)
  val create : ?ws_public_url:Uri.t -> base_url:Uri.t -> unit -> t
  val local : ?port:int -> unit -> t
  val mainnet : unit -> t
  val testnet : unit -> t
end
val read_only : t -> Read_only.t          (* drops key, secret and the private stream *)
```

`Read_only.t` has no credential field, so code holding one cannot sign a request or
authenticate a stream: `Public_ws.connect` and `Live_feed.connect` take a `Read_only.t`;
`Private_ws`, the trading `Rest` calls and `Venue` take the full `t`.

`create` derives the websocket URLs from `base_url` (`ws`/`wss`, paths
`/v5/public/linear` and `/v5/private`). `recv_window` defaults to 5000 ms. The secret is
redacted in `sexp_of_t`.

### `Rest`

```ocaml
val instruments_info : ?symbol:Symbol.t -> Config.t -> Instruments_info.Instrument.t list ...
val orderbook        : ?limit:int -> Config.t -> Symbol.t -> Orderbook.t ...
val tickers          : ?symbol:Symbol.t -> Config.t -> Tickers.Ticker.t list ...
val create_order     : Config.t -> Create_order.Params.t -> Order_ack.t ...
val create_batch     : Config.t -> Create_order.Params.t list
  -> (Create_batch.Item.t, Envelope.error) Result.t list ...
val cancel_order     : ?order_id:Order_id.t -> ?order_link_id:Order_link_id.t
  -> Config.t -> symbol:Symbol.t -> Order_ack.t ...
val cancel_all       : Config.t -> symbol:Symbol.t -> Order_ack.t list ...
val amend_order      : ?order_id -> ?order_link_id -> ?qty:Size.t -> ?price:Price.t
  -> Config.t -> symbol:Symbol.t -> Order_ack.t ...
val realtime_orders  : ?symbol -> ?settle_coin:string -> ?order_id -> ?order_link_id
  -> Config.t -> Realtime_order.t list ...
val executions       : ?symbol -> ?order_id -> ?limit:int -> Config.t -> Execution.t list ...
val positions        : ?symbol -> ?settle_coin:string -> Config.t -> Position.t list ...
val wallet_balance   : ?account_type:string -> Config.t -> Wallet_balance.t ...
```

- Private requests carry `X-BAPI-API-KEY`, `X-BAPI-TIMESTAMP` (now, ms),
  `X-BAPI-RECV-WINDOW` and `X-BAPI-SIGN = HMAC-SHA256(secret, timestamp ^ apiKey ^
  recvWindow ^ payload)`, where `payload` is the query string for GET and the JSON body
  for POST. Both are built once and the same bytes are signed and sent. Without
  `api_secret` the signature header is left out, which only the simulator accepts.
- Every response is decoded as Bybit's envelope, whatever the HTTP status. A non-zero
  `retCode` is an `Error` from which `Rest.Api_error.of_error` recovers
  `{ path; ret_code; error : Envelope.Error.t; ret_msg }`, so callers can tell a venue
  rejection from a transport failure.
- `create_batch` pairs each item with its `retExtInfo` status: a non-zero code is `Error`
  for that item.
- `realtime_orders` and `positions` send `settleCoin=USDT` when no symbol is given;
  Bybit requires one of the two for `linear`, also when looking up an order by id.
- `get_public`, `get_private` and `post_private` expose the transport for endpoints not
  listed here; `query_string`, `auth_headers` and `decode` are the pure steps.

### `Public_ws`, `Private_ws`

```ocaml
val Public_ws.connect : ?ping_interval -> ?initial_backoff -> ?max_backoff
  -> ?on_reconnect:(unit -> unit) -> ?on_raw:(string -> unit)
  -> ?on_frame:(string -> Ws_message.t Or_error.t -> unit)
  -> ?time_source:Time_source.t -> Config.Read_only.t
  -> Public_ws.t Or_error.t Deferred.t
val Public_ws.reconnects : t -> int
val Public_ws.subscribe / unsubscribe / resubscribe : t -> Topic.t -> unit Deferred.t
val Public_ws.messages : t -> Ws_message.t Pipe.Reader.t

val Private_ws.connect : ... -> ?subscribe:Topic.t list -> Config.t -> ...
```

- Built on `Venue_net.Ws_client`: `{"op":"ping"}` every 20 s (Bybit's recommendation); a
  connection silent for two intervals is replaced; reconnects use exponential backoff
  (0.5 s doubling to 30 s).
- On every (re)connection the private stream first authenticates with
  `{"op":"auth","args":[apiKey, expires, HMAC-SHA256(secret, "GET/realtime" ^ expires)]}`
  (`expires` 10 s ahead), waits for the auth ack, then replays the subscriptions. The
  public stream replays its subscriptions directly. `on_reconnect` runs afterwards.
- `on_raw` sees each frame before decoding; `intercept` can then claim it (it is not
  decoded, not passed on and not written to `messages`); `on_frame` sees every other
  frame with its (single) decoding; `time_source` (default the wall clock) drives the keepalive, the watchdog and
  the backoff, so tests can step reconnects with a synthetic clock.
- `subscribe` is idempotent. A topic subscribed while a connection is still
  authenticating is sent by the replay, so it goes out once.
- `resubscribe` sends `unsubscribe` and `subscribe`, which makes the server send a new
  snapshot (used on orderbook gaps).
- `Private_ws.connect` subscribes to `order`, `execution`, `position` and `wallet` by
  default.
- `messages` carries every decoded message (acks, both pong shapes, pushes, `Unknown`
  topics); undecodable frames are logged at debug level and dropped. Buffered without
  pushback.

### `Local_book`

A local orderbook from `orderbook.<depth>.<symbol>` pushes. A snapshot replaces the book
(also `u = 1`, Bybit's restart signal). A delta must have `u = previous + 1`: size `0`
removes a level, any other size sets it. `apply` returns `Applied`, `Stale` (`u` not
above the current one), `Waiting_for_snapshot` (before the first snapshot or after a gap)
or `Gap { expected; received }`, after which the book is dropped until a new snapshot.
`to_l2 ?depth` gives an `Exchange_core.L2.t` (order counts `n = 0`, which Bybit does not
send); `best_bid` and `best_ask` give the top level without building it. `apply_scan`
applies a frame read by `Frame_scan` with the same rules.

### `Live_feed`: normalized market data

```ocaml
val Live_feed.connect
  :  ?on_raw:(stream:Market_data.Stream.t -> recv_ts:Time_ns.t -> string -> unit)
  -> ?l2_depth:int
  -> ?time_source:Time_source.t
  -> Config.Read_only.t -> symbols:string list -> streams:Market_data.Stream.t list
  -> Live_feed.t Deferred.t
val Live_feed.feed  : t -> Market_data.Feed.t
val Live_feed.feed_with_gaps : t -> Market_data.Feed.With_gaps.t
val Live_feed.stats : t -> (Market_data.Stream.t * Stats.t) list
  (* Stats.t = { frames; parse_errors; reconnects } per stream *)

val Live_feed.create   (* connect with Config.read_only, then feed *)
  :  ?on_raw:... -> ?l2_depth:int
  -> Config.t -> symbols:string list -> streams:Market_data.Stream.t list
  -> Market_data.Feed.t Deferred.t
```

A [market-data](https://github.com/winterchill-trading/market-data) `Feed.t` over the
public stream, read-only, no credentials. One `Public_ws` connection per requested
stream, so a frame's stream is known before it is parsed:

| stream    | topic                        | record                                                  |
|-----------|------------------------------|---------------------------------------------------------|
| `trades`  | `publicTrade.<symbol>`       | one `Trade.t` per print, `exch_ts` = `T`                |
| `bbo`     | `orderbook.1.<symbol>`       | `Bbo.t` after each applied push with both sides, `ts`   |
| `l2`      | `orderbook.<depth>.<symbol>` | snapshots and deltas as `L2_update.t` (depth 50), `ts`  |
| `funding` | `tickers.<symbol>`           | `Funding.t` when rate, next time, mark or index change  |

- `recv_ts` is taken from `time_source` (default the wall clock) when the frame arrives;
  `on_raw` gets that frame unparsed first (acks and pongs included), which is what a
  `Frame_log` recorder stores.
- Trade and orderbook frames are read by `Frame_scan` (no JSON tree; see below) through
  `Public_ws`'s `intercept` hook; every other frame (acks, pongs, tickers, unusual
  shapes) is decoded once with Yojson (`on_frame`) and then normalized. The topic string,
  symbol, `Instrument.t` and local book are cached per subscription, so a scanned frame
  allocates only its events.
- `stats` counts frames, parse errors (frames that do not decode or normalize; they are
  logged and skipped) and reconnects, per stream.
- Books go through `Local_book`; a sequence gap resubscribes the topic and the next
  snapshot resynchronises. Ticker deltas are merged into the last snapshot.
- Reconnects (backoff, resubscription) come from `Public_ws`; Bybit answers each
  subscription with a fresh snapshot, so `l2` emits a `Snapshot` after a reconnect.
- `feed_with_gaps` adds a `gaps` pipe of `Market_data.Gap.t`, all with reason `Resync`:
  one per reconnect of a stream's socket (`instrument = None`, the whole connection) and
  one per book sequence gap (`instrument` set). A gap is written before any event of the
  new connection or the new snapshot, and is stamped from `time_source`. `feed` is the
  same feed without that pipe.
- Undecodable frames are logged, never fatal. `close` closes the sockets and all pipes.
- `Live_feed.Normalizer` is the pure frame-to-event part, used by the tests and by
  `Raw_normalizer`: `frame` scans then falls back to Yojson, `scan` is the fast path
  alone, `message` normalizes an already decoded message.

#### `Frame_scan`: the zero-allocation path

`Frame_scan.scan` is `[@zero_alloc]` (checked by the compiler) and reads a
`publicTrade.<symbol>` or `orderbook.<depth>.<symbol>` frame into a reused record:
prices and sizes as `Fixed_decimal` units, timestamps as integer milliseconds, strings as
positions into the frame. It walks the JSON object (any key order, unknown keys skipped)
and returns `false`, leaving the frame to Yojson, for anything outside the shapes Bybit
sends: other topics (rejected as soon as the topic is read), `op` frames, escaped
strings, string timestamps, exponents or signs in decimals, more than 10 integer digits,
missing fields, more than 1024 levels per side or trades per frame. Values of fields the
normalizer does not use are skipped without validation, so a frame that is malformed only
there is accepted by the scanner but rejected by Yojson. A test runs every recorded frame
through both paths and requires identical outputs, and `Local_book.apply_scan` is checked
against `Local_book.apply` the same way.

#### Reconnect frame loss

Bybit's public stream has no replay: nothing sent between the old socket's last frame
and the new socket's subscription is ever delivered. The window is

1. detection: immediate on a close or reset; a half-open socket is replaced after two
   silent 20 s ping intervals, so 40 to 60 s after its last frame;
2. backoff: 0.5 s with 20% jitter for the first attempt (0.4 to 0.6 s), doubling up to
   30 s while attempts fail;
3. connect, TLS and the subscribe round trip.

What the window costs per stream:

| stream    | lost                                   | recovered by                        |
|-----------|----------------------------------------|-------------------------------------|
| `trades`  | every print in the window, for good    | nothing (no history on subscribe)   |
| `bbo`     | intermediate top-of-book changes       | the `orderbook.1` snapshot          |
| `l2`      | intermediate deltas                    | the `orderbook.<depth>` snapshot    |
| `funding` | intermediate rate, mark, index changes | the `tickers` snapshot              |

Measured on the synthetic clock (`test_live_feed_stats.ml`, `test_live_feed_gaps.ml`,
loopback server, socket dropped at t = 0): the client opens no connection before the
backoff alarm, which falls between 0.4 and 0.6 s; after one advance of 1 s it has
reconnected and resubscribed (`connections 2`, `reconnects 1`), and the first frame of
the new socket is stamped `recv_ts` = 1.000 s with the `Resync` gap stamped the same and
written before it. Frames pushed to the old socket after the drop: none delivered, the
loopback has no connection to send them on. A sequence gap costs one more round trip
(unsubscribe, subscribe, snapshot) with the deltas in between dropped; its gap is stamped
with the frame that broke the sequence.

### `Raw_normalizer`: rebuilding `norm/` from raw files

`Raw_normalizer` is `Live_feed.Normalizer` as a `Market_data.Normalizer.S`, so
market-recorder raw minute files of Bybit can be turned back into event logs:

```ocaml
Market_data.Rebuild_norm.command [ (module Bybit_client.Raw_normalizer) ]
```

Books are kept per topic, so any `orderbook.<depth>` recording works. A disconnect line
calls `Live_feed.Normalizer.reset`, which drops books and tickers as a reconnect does:
deltas are skipped until the next snapshot, and the next ticker snapshot emits a funding
record. Gap resubscriptions cannot be sent while rebuilding; the book waits for the
snapshot the live feed asked for, which is in the recording.

### `Id_map`

Bybit's `orderId` and `execId` are strings: decimal numbers on some products and in the
simulator, UUIDs on others. `exchange-core` uses integers. The mapping:

- a decimal string that fits a non-negative `int64` maps to that number (no table, and
  ids read the same on both sides);
- any other string gets the next negative number (`-1`, `-2`, ...) and is remembered, so
  the same string always maps to the same id and the two ranges never collide.

`to_bybit_order_id` maps back; a negative id the map never handed out has no Bybit
counterpart. Negative ids are only stable for the lifetime of the map (one per `Venue.t`).

### `Venue`: the `Mm_core.Venue.S` adapter

`Bybit_client.Venue` implements `Mm_core.Venue.S with type config = Config.t`.

| Function | Bybit |
| --- | --- |
| `connect` | needs `api_key` (and `api_secret` for the real API); opens the public and private streams |
| `instrument` | `instruments-info` -> `Instrument.to_exchange_core`, cached |
| `books` | `orderbook.50.<symbol>` merged by `Local_book`; a gap resubscribes; a new reader gets the current book first |
| `fills` | `execution` topic, types `Trade`, `AdlTrade`, `BustTrade`, de-duplicated by `execId` |
| `order_updates` | `order` topic |
| `open_orders` | `GET /v5/order/realtime?symbol=` |
| `account` | `wallet-balance` (`UNIFIED`) and `position/list` (`settleCoin=USDT`) |
| `place` | `create` for one order, `create-batch` (20 per request) for more, then a read-back |
| `cancel` | one `cancel` per id; `110001` (already gone) is not an error |
| `cancel_all` | `cancel-all` for the symbol |

Decisions:

- **Fill de-duplication.** Each `execId` is delivered at most once per `Venue.t`
  (a hash set of seen ids). The `execution` topic sends no snapshot on (re)subscription,
  so fills from before `connect` never appear. `Fill.trade_id` is the `Id_map` image of
  the `execId`; `closed_pnl` is `None` (Bybit reports closed PnL per order and position,
  not per fill).
- **Single reader.** `fills` and `order_updates` are one pipe each, buffered from
  `connect`; read each from a single consumer, as the `Venue.S` contract says.
- **Order outcomes.** Bybit only acknowledges `create`; the order's fate is
  asynchronous. `place` reads it back: the open orders of each symbol in one request,
  then the remaining acknowledged orders by id. Open orders are `Resting`; orders with
  any fill are `Filled` (cumulative size, average price); others are `Rejected` with the
  mapped `rejectReason` (`EC_PostOnlyWillTakeLiquidity` is `Post_only_would_cross`). An
  order not visible yet counts as `Resting`; the `order` topic then reports its fate.
- **Rejections.** A non-zero `retCode` on `create` (or on a batch item) is
  `Rejected`: `110072` duplicate client id, `110004`/`110007` insufficient margin,
  `110017` reduce-only with nothing to reduce, `110003` invalid price, `110001` order not
  found, anything else `Unsupported "<code> <msg>"`. Client ids that break Bybit's
  36-character `[A-Za-z0-9_-]` rule are rejected locally.
- **Order types.** `Alo` is `PostOnly`, `Gtc` and `Ioc` map directly; market orders
  are Bybit market orders and `slippage_bps` is ignored.
- **Order updates.** An order the venue cancelled with a reject reason and nothing filled
  (post-only crossing, IOC without liquidity, self-match) is `Rejected`, since it never
  rested; other cancellations are `Cancelled`.
- **Account.** `balance` is `totalWalletBalance`, `equity` `totalEquity`, `margin_used`
  `totalInitialMargin`, `available` `totalAvailableBalance`. Positions:
  `realized_pnl` is Bybit's `cumRealisedPnl` (after fees and funding, unlike the
  contract's "before fees"), `cum_funding` is zero, `max_leverage` comes from
  instruments fetched with `instrument` (else the position's leverage). `time` is the
  local clock (the wallet response has no timestamp).

## CLI

`bybit-cli` (`bin/bybit_cli.ml`) is a smoke-testing tool. Credentials come from the
environment (`BYBIT_API_KEY`, `BYBIT_API_SECRET`), never from flags.

```sh
bybit-cli orderbook BTCUSDT -limit 5                 # simulator on localhost:3400
bybit-cli tickers BTCUSDT -testnet
bybit-cli watch -orderbook BTCUSDT -trades BTCUSDT -tickers BTCUSDT
BYBIT_API_KEY=mm bybit-cli watch -private            # order, execution, position, wallet
bybit-cli watch -orderbook BTCUSDT -base-url http://localhost:3471 -debug
bybit-cli feed -symbol BTCUSDT -streams trades,bbo     # Market_data.Event.t sexps
bybit-cli feed -symbol BTCUSDT,ETHUSDT -streams l2,funding -depth 200 -mainnet
bybit-cli rebuild-norm -data-dir DIR -out NEW_DIR -date YYYY-MM-DD
```

`feed` takes `-count N` to stop after N events. `rebuild-norm` reads a day of recorder
raw files (`<data-dir>/raw/bybit/...`) and writes `<out>/bybit/<symbol>/norm/<stream>/`
event logs; `out` must be new or empty.

## Running against the simulator

```sh
dune exec bybit-sim -- -port 3400 &          # from the bybit-sim checkout
BYBIT_API_KEY=mm bybit-cli watch -private -orderbook BTCUSDT
bybit-cli feed -symbol BTCUSDT -streams trades,bbo -count 8
```

The last command, verified against the simulator, prints normalized events such as

```
(Bbo
 ((instrument ((venue Bybit) (symbol BTCUSDT)))
  (exch_ts (2026-10-12 12:19:55.402000000+01:00))
  (recv_ts (2026-10-12 12:19:55.402669000+01:00)) (bid_price 100077.8)
  (bid_size 0.456) (ask_price 100088.4) (ask_size 0.279)))
(Trade
 ((instrument ((venue Bybit) (symbol BTCUSDT)))
  (exch_ts (2026-10-12 12:19:55.664000000+01:00))
  (recv_ts (2026-10-12 12:19:55.665206000+01:00)) (price 100066.9)
  (size 0.539) (side Sell) (trade_id 83)))
```

Restarting the simulator under a running `feed -streams l2` shows the reconnect: the
client retries with backoff, resubscribes and prints a new `Snapshot`.

The simulator takes the account from `X-BAPI-API-KEY` (any key works and is credited
1,000,000 USDT on first use), checks `X-BAPI-TIMESTAMP` against `X-BAPI-RECV-WINDOW`,
and does not check signatures, so `Config.local ~api_key:"mm" ()` without a secret is
enough. Its order ids are decimal (the engine's), except for orders the engine never
created (post-only crossing, IOC without liquidity), which get UUID-shaped ids and so
negative `Order_id`s in the adapter.

## Running against Bybit testnet

Create API keys on [testnet.bybit.com](https://testnet.bybit.com) (unified trading
account, contract trading permission), then:

```sh
export BYBIT_API_KEY=... BYBIT_API_SECRET=...
bybit-cli tickers BTCUSDT -testnet
bybit-cli watch -private -testnet
```

In code: `Config.testnet ~api_key ~api_secret ()`, read from the same variables. Keys and
secrets should never be committed or passed on the command line. The clock must be within
`recv_window` (5 s) of Bybit's, otherwise requests fail with `10002`.

## Tests

`dune test` runs without network access:

- pure tests: config and URL derivation, query strings, signed headers (with and
  without a secret), envelope and `retCode` decoding, `Local_book` sequencing (stale
  deltas, a gap, resync on snapshot, `u = 1` restart), `Id_map`, and every `Venue`
  conversion (orders, updates, fills, order requests, reject reasons, account);
- `Live_feed.Normalizer` on sample frames from the docs: trades, `orderbook.50` snapshot,
  delta and gap (resubscribe), `orderbook.1` into BBO, ticker snapshot and deltas into
  funding, acks, unknown topics and junk;
- recorded mainnet frames (`test/fixtures`, 20 s of BTCUSDT per stream, see its README):
  every frame decodes, and the normalizer turns them into 487 trades, 579 BBOs, 1 L2
  snapshot plus 849 deltas, and 42 funding records with no parse error or gap; the
  scanner and Yojson paths give identical outputs on every frame (1653 of 1837 frames
  scanned); minor words per frame for decoding, normalizing and `Normalizer.frame` are
  pinned, and `Frame_scan.scan` allocates 0 words over every trade and book frame;
- the same fixtures through `Raw_normalizer` (same counts; after a `disconnect` deltas
  are dropped until a snapshot), and `Market_data.Rebuild_norm` over raw minute files
  written from them with a disconnect in the L2 series: 1837 frames, 1507 events, four
  clean event logs;
- `Live_feed` against a loopback websocket server: malformed frames counted as parse
  errors and skipped, a reconnect stepped on a synthetic `Time_source` (no reconnect
  before the backoff elapses, resubscription after it, `recv_ts` from the synthetic
  clock, `reconnects = 1`), `Resync` gaps on a reconnect and on a book sequence gap,
  and an allocation bound for the single-decode live path;
- an integration test that starts `Bybit_sim.Server` on a free port and exercises every
  `Rest` endpoint, both websocket streams (subscribe, resubscribe snapshot, both pong
  shapes, auth, private pushes), and the `Venue` adapter end to end: books, a post-only
  bid that rests and shows in `open_orders`, a crossing post-only order rejected, cancel
  (twice), cancel-all, an IOC order that fills, the fill delivered once, the order update
  sequence, and the account view with the resulting position.

The simulator runs on the wall clock (the timestamp and auth checks compare against it),
so the integration test leaves timestamps out of its output.

## Benchmarks

`bench/main.exe` runs core_bench over the recorded frames (run it from the repository
root, or set `BYBIT_FIXTURES`): Yojson decode, `Frame_scan.scan`, normalize a decoded
message, and `Normalizer.frame` (scan, else decode and normalize), per frame and stream.

`Normalizer.frame` per frame, minor words in brackets, on an arm64 Mac (shared and busy,
so times are within about 10%; words are exact; CI is amd64). Before is the Yojson path
(`8c2d766`), after is the scanner:

| stream (bytes/frame) | dev before    | dev after    | release before | release after | `-O3` before  | `-O3` after  |
| -------------------- | ------------- | ------------ | -------------- | ------------- | ------------- | ------------ |
| trades (452)         | 5.6 us (806)  | 1.1 us (54)  | 4.9 us (801)   | 1.1 us (54)   | 4.9 us (800)  | 1.0 us (52)  |
| bbo (195)            | 2.6 us (577)  | 0.52 us (77) | 2.5 us (573)   | 0.47 us (73)  | 2.5 us (564)  | 0.43 us (45) |
| l2 (366)             | 6.0 us (1327) | 1.5 us (536) | 5.3 us (1323)  | 1.4 us (528)  | 5.3 us (1321) | 1.3 us (484) |
| funding (236)        | 2.7 us (473)  | 2.6 us (473) | 2.6 us (469)   | 2.7 us (469)  | 2.5 us (467)  | 2.6 us (467) |

`Frame_scan.scan` alone (release): trades 1.0 us, bbo 0.40 us, l2 0.72 us, 0 words (the
bench shows 3, its own closure overhead); a ticker frame is rejected in 59 ns. What the
scanned path still allocates is the events themselves (records, level lists, trade id
strings) and the local book's map updates; funding frames stay on Yojson.

```sh
dune exec bench/main.exe -- -quota 1 -ascii
dune exec --profile release bench/main.exe -- -quota 1 -ascii
OCAMLPARAM='_,O3=1' dune exec --profile release bench/main.exe -- -quota 1 -ascii
```

## UNVERIFIED

Inherited from [bybit-protocol](https://github.com/winterchill-trading/bybit-protocol)
(implemented by assumption, could not be confirmed from the docs):

- Error envelopes use the same keys with a non-zero `retCode`; `result` may be `{}`.
- The GET signing string is the query string exactly as sent (this client signs the
  percent-encoded string it sends).
- Linear-specific examples for tickers, position list and create-batch were not
  available (inverse/spot examples were used).
- Websocket subscribe failures and the auth ack use the `Op_response` shape
  (`success: false`, reason in `ret_msg`).
- Ticker deltas always include `symbol`.
- Reduce-only rejection has no dedicated retCode (110017 is used).
- Recv window maximum, rate limits and orderbook depth 500 are not modelled.

Added here, checked against the simulator only:

- Bybit accepts `subscribe` on the private stream only after the auth ack; the client
  waits for it (10 s timeout, then subscribes anyway and logs an error).
- Orderbook `u` is consecutive per topic on the real API as in the simulator; a jump is
  treated as a gap and resubscribed.
- `GET /v5/order/realtime` by `orderId` (plus `symbol`) returns recently closed orders,
  which the order read-back after `place` relies on. If the real API needs
  `openOnly=1` for that, orders that closed immediately are reported as `Resting` and
  their fate arrives on the `order` topic.
- The `execution` topic sends no snapshot on (re)subscription.
- `create-batch` returns one `list` item per request item, in order.
