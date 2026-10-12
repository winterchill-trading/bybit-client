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
for p in fixed-decimal exchange-core order-book; do
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
```

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
  -> ?on_reconnect:(unit -> unit) -> Config.t -> Public_ws.t Or_error.t Deferred.t
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
send).

### `Live_feed`: normalized market data

```ocaml
val Live_feed.create
  :  ?on_raw:(stream:Market_data.Stream.t -> recv_ts:Time_ns.t -> string -> unit)
  -> ?l2_depth:int
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

- `recv_ts` is taken when the frame arrives; `on_raw` gets that frame unparsed first (acks
  and pongs included), which is what a `Frame_log` recorder stores.
- Books go through `Local_book`; a sequence gap resubscribes the topic and the next
  snapshot resynchronises. Ticker deltas are merged into the last snapshot.
- Reconnects (backoff, resubscription) come from `Public_ws`; Bybit answers each
  subscription with a fresh snapshot, so `l2` emits a `Snapshot` after a reconnect.
- Undecodable frames are logged, never fatal. `close` closes the sockets and all pipes.
- `Live_feed.Normalizer` is the pure frame-to-event part, used by the tests.

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
```

`feed` takes `-count N` to stop after N events.

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
- an integration test that starts `Bybit_sim.Server` on a free port and exercises every
  `Rest` endpoint, both websocket streams (subscribe, resubscribe snapshot, both pong
  shapes, auth, private pushes), and the `Venue` adapter end to end: books, a post-only
  bid that rests and shows in `open_orders`, a crossing post-only order rejected, cancel
  (twice), cancel-all, an IOC order that fills, the fill delivered once, the order update
  sequence, and the account view with the resulting position.

The simulator runs on the wall clock (the timestamp and auth checks compare against it),
so the integration test leaves timestamps out of its output.

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
