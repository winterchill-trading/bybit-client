(* Rest and Venue against the simulator, over HTTP and websockets on a free port. The
   simulator runs on the wall clock (the REST timestamp check and the websocket auth
   expiry compare against it), so timestamps are left out of the output. *)

open! Core
open! Async
open Bybit_protocol
open Bybit_client
module Neutral = Exchange_core

let btc = Symbol.of_string "BTCUSDT"

let with_sim f =
  Log.Global.set_output [];
  let server = Bybit_sim.Server.create (Bybit_sim.Adapt.create_exchange ()) in
  let%bind http = Bybit_sim.Server.listen server ~port:0 in
  let port = Bybit_sim.Server.port http in
  let config api_key = Config.local ~port ~api_key () in
  let%bind () = f config in
  Cohttp_async.Server.close http
;;

let ok_exn d = Deferred.map d ~f:Or_error.ok_exn

(* Waiting with [values_available] rather than [read] leaves nothing behind on timeout: an
   abandoned [read] would swallow the next value. *)
let available r ~timeout =
  match%map Clock_ns.with_timeout timeout (Pipe.values_available r) with
  | `Result `Ok -> true
  | `Result `Eof | `Timeout -> false
;;

(* The next element of [r], waiting at most 5s. *)
let next r =
  if%map available r ~timeout:(Time_ns.Span.of_int_sec 5)
  then (
    match Pipe.read_now r with
    | `Ok x -> Some x
    | `Eof | `Nothing_available -> None)
  else None
;;

(* Everything [r] delivers until it has been quiet for 300ms. *)
let drain r =
  let rec loop acc =
    if%bind available r ~timeout:(Time_ns.Span.of_int_ms 300)
    then (
      match Pipe.read_now' r with
      | `Ok q -> loop (acc @ Queue.to_list q)
      | `Eof | `Nothing_available -> return acc)
    else return acc
  in
  loop []
;;

let limit ?(tif = Neutral.Tif.Gtc) ?cloid side ~px ~size =
  Neutral.Order_request.limit
    ~tif
    ?client_order_id:(Option.map cloid ~f:Neutral.Client_order_id.of_string)
    btc
    side
    ~px:(Price.of_string px)
    ~size:(Size.of_string size)
;;

let print_book (l2 : Neutral.L2.t) =
  let side levels =
    List.map levels ~f:(fun (l : Neutral.L2.Level.t) ->
      sprintf "%s@%s" (Size.to_string l.sz) (Price.to_string l.px))
    |> String.concat ~sep:" "
  in
  printf
    "book %s: bids [%s] asks [%s]\n"
    (Symbol.to_string l2.symbol)
    (side l2.bids)
    (side l2.asks)
;;

let print_open_orders orders =
  List.iter orders ~f:(fun (o : Neutral.Open_order.t) ->
    printf
      "open %s %s %s@%s %s\n"
      (Neutral.Order_id.to_string o.order_id)
      (Side.to_wire o.side)
      (Size.to_string o.size)
      (Price.to_string o.px)
      (Option.value_map
         o.client_order_id
         ~default:"-"
         ~f:Neutral.Client_order_id.to_string));
  if List.is_empty orders then print_endline "no open orders"
;;

let print_updates updates =
  List.iter updates ~f:(fun (u : Mm_core.Order_update.t) ->
    printf
      "update %s %s %s@%s filled %s remaining %s\n"
      (Neutral.Order_id.to_string u.order_id)
      (Sexp.to_string [%sexp (u.status : Mm_core.Order_update.Status.t)])
      (Side.to_wire u.side)
      (Price.to_string u.px)
      (Size.to_string u.filled)
      (Size.to_string u.remaining))
;;

let%expect_test "Rest against the simulator" =
  with_sim (fun config ->
    let%bind instruments = Rest.instruments_info (config "x") |> ok_exn in
    print_s
      [%sexp
        (List.map instruments ~f:(fun (i : Instruments_info.Instrument.t) ->
           i.symbol, i.price_filter.tick_size, i.lot_size_filter.qty_step)
         : (Symbol.t * Price.t * Size.t) list)];
    [%expect {| ((BTCUSDT 0.1 0.001) (ETHUSDT 0.01 0.01) (SOLUSDT 0.01 0.1)) |}];
    let other = config "other" in
    let%bind ack =
      Rest.create_order
        other
        (Create_order.Params.limit
           btc
           ~side:Sell
           ~qty:(Size.of_string "0.01")
           ~price:(Price.of_string "100000")
           ~order_link_id:(Order_link_id.of_string "o-1"))
      |> ok_exn
    in
    print_s [%sexp (ack : Order_ack.t)];
    [%expect {| ((order_id 1) (order_link_id (o-1))) |}];
    let%bind batch =
      Rest.create_batch
        other
        [ Create_order.Params.limit
            btc
            ~side:Buy
            ~qty:(Size.of_string "0.01")
            ~price:(Price.of_string "99000")
        ; Create_order.Params.limit
            btc
            ~side:Buy
            ~qty:(Size.of_string "0.01")
            ~price:(Price.of_string "99000")
            ~order_link_id:(Order_link_id.of_string "o-1")
        ]
      |> ok_exn
    in
    print_s
      [%sexp
        (List.map
           batch
           ~f:
             (Result.map ~f:(fun (item : Create_batch.Item.t) ->
                { item with create_at = None }))
         : (Create_batch.Item.t, Envelope.error) Result.t list)];
    [%expect
      {|
      ((Ok
        ((category Linear) (symbol BTCUSDT) (order_id 2) (order_link_id ())
         (create_at ())))
       (Error
        ((error Duplicate_order_link_id) (ret_msg "OrderLinkedID is duplicate"))))
      |}];
    let%bind book = Rest.orderbook ~limit:5 other btc |> ok_exn in
    print_book (Orderbook.to_exchange_core book);
    [%expect {| book BTCUSDT: bids [0.01@99000] asks [0.01@100000] |}];
    let%bind tickers = Rest.tickers ~symbol:btc other |> ok_exn in
    print_s
      [%sexp
        (List.map tickers ~f:(fun t -> t.bid1_price, t.ask1_price)
         : (Price.t option * Price.t option) list)];
    [%expect {| (((99000) (100000))) |}];
    let%bind amended =
      Rest.amend_order
        ~order_link_id:(Order_link_id.of_string "o-1")
        ~price:(Price.of_string "100500")
        other
        ~symbol:btc
      |> ok_exn
    in
    print_s [%sexp (amended : Order_ack.t)];
    [%expect {| ((order_id 1) (order_link_id (o-1))) |}];
    let%bind orders = Rest.realtime_orders ~symbol:btc other |> ok_exn in
    print_s
      [%sexp
        (List.map orders ~f:(fun o -> o.order_id, o.side, o.price, o.order_status)
         : (Order_id.t * Side.t * Price.t * Order_status.t) list)];
    [%expect {| ((2 Buy 99000 New) (1 Sell 100500 New)) |}];
    let%bind cancelled =
      Rest.cancel_order ~order_id:(Order_id.of_string "2") other ~symbol:btc
    in
    print_s [%sexp (cancelled : Order_ack.t Or_error.t)];
    [%expect {| (Ok ((order_id 2) (order_link_id ()))) |}];
    let%bind again =
      Rest.cancel_order ~order_id:(Order_id.of_string "2") other ~symbol:btc
    in
    print_s
      [%sexp
        (Result.error again |> Option.bind ~f:Rest.Api_error.of_error
         : Rest.Api_error.t option)];
    [%expect
      {|
      (((path /v5/order/cancel) (ret_code 110001) (error Order_not_exists)
        (ret_msg "Order does not exist")))
      |}];
    let%bind wallet = Rest.wallet_balance other |> ok_exn in
    print_s
      [%sexp
        (List.map wallet.list ~f:(fun a -> a.total_wallet_balance, a.total_initial_margin)
         : (Usd.t * Usd.t option) list)];
    [%expect {| ((1000000 (0))) |}];
    let%bind positions = Rest.positions ~symbol:btc other |> ok_exn in
    print_s
      [%sexp
        (List.map positions ~f:(fun p -> p.symbol, p.side, p.size)
         : (Symbol.t * Side.t option * Size.t) list)];
    [%expect {| ((BTCUSDT () 0)) |}];
    let%bind executions = Rest.executions other |> ok_exn in
    print_s [%sexp (List.length executions : int)];
    [%expect {| 0 |}];
    let%bind all = Rest.cancel_all other ~symbol:btc |> ok_exn in
    print_s [%sexp (all : Order_ack.t list)];
    [%expect {| (((order_id 1) (order_link_id (o-1)))) |}];
    let%bind unauthenticated = Rest.wallet_balance (Config.local ()) in
    print_s [%sexp (Result.is_error unauthenticated : bool)];
    [%expect {| true |}];
    return ())
;;

let%expect_test "Venue against the simulator" =
  with_sim (fun config ->
    let other = config "other" in
    (* Another account makes a market: 0.01 bid at 99000, 0.01 ask at 100000. *)
    let%bind (_ : Order_ack.t list) =
      Deferred.List.map
        ~how:`Sequential
        [ Side.Buy, "99000"; Sell, "100000" ]
        ~f:(fun (side, px) ->
          Rest.create_order
            other
            (Create_order.Params.limit
               btc
               ~side
               ~qty:(Size.of_string "0.01")
               ~price:(Price.of_string px))
          |> ok_exn)
    in
    let%bind venue = Venue.connect (config "mm") |> ok_exn in
    let%bind instrument = Venue.instrument venue btc |> ok_exn in
    print_s [%sexp (instrument : Neutral.Instrument.t)];
    [%expect
      {|
      ((symbol BTCUSDT) (size_decimals 3) (price_tick 0.1)
       (max_significant_figures ()) (max_leverage 100)
       (fees ((taker_bps 3.5) (maker_bps 1))))
      |}];
    let%bind books = Venue.books venue btc in
    let%bind book = next books in
    Option.iter book ~f:print_book;
    [%expect {| book BTCUSDT: bids [0.01@99000] asks [0.01@100000] |}];
    (* A post-only bid inside the spread rests; a post-only sell at the bid would cross. *)
    let%bind statuses =
      Venue.place
        venue
        [ limit ~tif:Alo ~cloid:"mm-b-1" Buy ~px:"99500" ~size:"0.01"
        ; limit ~tif:Alo ~cloid:"mm-a-1" Sell ~px:"99000" ~size:"0.01"
        ; limit
            ~tif:Alo
            ~cloid:"this-client-order-id-is-much-too-long-for-bybit"
            Buy
            ~px:"1"
            ~size:"1"
        ]
      |> ok_exn
    in
    print_s [%sexp (statuses : Neutral.Order_status.t list)];
    [%expect
      {|
      ((Resting (order_id 3) (client_order_id (mm-b-1)))
       (Rejected (Post_only_would_cross (best_bid ()) (best_ask ())))
       (Rejected
        (Unsupported "client order id: at most 36 characters from [A-Za-z0-9_-]")))
      |}];
    let%bind single =
      Venue.place venue [ limit ~tif:Alo Buy ~px:"99400" ~size:"0.02" ] |> ok_exn
    in
    print_s [%sexp (single : Neutral.Order_status.t list)];
    [%expect {| ((Resting (order_id 5) (client_order_id ()))) |}];
    let%bind orders = Venue.open_orders venue btc |> ok_exn in
    print_open_orders orders;
    [%expect {|
      open 5 Buy 0.02@99400 -
      open 3 Buy 0.01@99500 mm-b-1
      |}];
    let%bind book = next books in
    Option.iter book ~f:print_book;
    [%expect
      {| book BTCUSDT: bids [0.01@99500 0.02@99400 0.01@99000] asks [0.01@100000] |}];
    let resting_bid =
      List.find_map_exn orders ~f:(fun o ->
        Option.some_if (Price.equal o.px (Price.of_string "99500")) o.order_id)
    in
    let%bind () = Venue.cancel venue btc [ resting_bid ] |> ok_exn in
    (* Cancelling again is not an error. *)
    let%bind () = Venue.cancel venue btc [ resting_bid ] |> ok_exn in
    let%bind orders = Venue.open_orders venue btc |> ok_exn in
    print_open_orders orders;
    [%expect {| open 5 Buy 0.02@99400 - |}];
    let%bind () = Venue.cancel_all venue btc |> ok_exn in
    let%bind orders = Venue.open_orders venue btc |> ok_exn in
    print_open_orders orders;
    [%expect {| no open orders |}];
    (* Cross the spread: an IOC buy at the ask fills against the other account. *)
    let%bind statuses =
      Venue.place venue [ limit ~tif:Ioc ~cloid:"mm-x-1" Buy ~px:"100000" ~size:"0.004" ]
      |> ok_exn
    in
    print_s [%sexp (statuses : Neutral.Order_status.t list)];
    [%expect
      {|
      ((Filled (order_id 6) (total 0.004) (avg_px 100000)
        (client_order_id (mm-x-1))))
      |}];
    let%bind fill = next (Venue.fills venue) in
    print_s
      [%sexp (Option.map fill ~f:(fun f -> { f with time = 0 }) : Mm_core.Fill.t option)];
    [%expect
      {|
      (((trade_id 1) (order_id 6) (client_order_id (mm-x-1)) (symbol BTCUSDT)
        (side Buy) (px 100000) (size 0.004) (fee 0.22) (is_maker false) (time 0)
        (closed_pnl ())))
      |}];
    let%bind more_fills = drain (Venue.fills venue) in
    print_s [%sexp (List.length more_fills : int)];
    [%expect {| 0 |}];
    let%bind updates = drain (Venue.order_updates venue) in
    print_updates updates;
    [%expect
      {|
      update 3 New Buy@99500 filled 0 remaining 0.01
      update -1 Rejected Sell@99000 filled 0 remaining 0
      update 5 New Buy@99400 filled 0 remaining 0.02
      update 3 Cancelled Buy@99500 filled 0 remaining 0
      update 5 Cancelled Buy@99400 filled 0 remaining 0
      update 6 Filled Buy@100000 filled 0.004 remaining 0
      |}];
    let%bind account = Venue.account venue |> ok_exn in
    print_s [%sexp ({ account with time = 0 } : Neutral.Account_view.t)];
    [%expect
      {|
      ((account mm) (balance 999999.78) (equity 999999.78) (total_notional 400)
       (margin_used 40) (maintenance_margin 2) (available 999959.78)
       (positions
        (((symbol BTCUSDT) (size 0.004) (entry_px 100000) (notional 400)
          (unrealized_pnl 0) (realized_pnl -0.22) (cum_funding 0)
          (liquidation_px ()) (leverage 10) (max_leverage 100) (margin_used 40))))
       (time 0))
      |}];
    let%bind () = Venue.close venue in
    let%bind () = Venue.close venue in
    print_s [%sexp (Pipe.is_closed (Venue.fills venue) : bool)];
    [%expect {| true |}];
    return ())
;;

let describe (message : Ws_message.t) =
  match message with
  | Subscribe_ack r ->
    sprintf "subscribe ack success=%b" (Option.value r.success ~default:false)
  | Auth_ack r -> sprintf "auth ack success=%b" (Option.value r.success ~default:false)
  | Pong r -> sprintf "pong op=%s" r.op
  | Orderbook o ->
    sprintf
      "orderbook %s %s bids=%d asks=%d"
      (Update_type.to_wire o.type_)
      (Symbol.to_string o.data.s)
      (List.length o.data.b)
      (List.length o.data.a)
  | Order p -> sprintf "order x%d" (List.length p.data)
  | Execution p -> sprintf "execution x%d" (List.length p.data)
  | Position p -> sprintf "position x%d" (List.length p.data)
  | Wallet p -> sprintf "wallet x%d" (List.length p.data)
  | Op_response _ | Public_trade _ | Ticker _ | Unknown _ -> "other"
;;

let print_messages r =
  let%map messages = drain r in
  List.iter messages ~f:(fun m -> print_endline (describe m))
;;

let%expect_test "public and private streams" =
  with_sim (fun config ->
    let other = config "other" in
    let%bind (_ : Order_ack.t) =
      Rest.create_order
        other
        (Create_order.Params.limit
           btc
           ~side:Buy
           ~qty:(Size.of_string "0.01")
           ~price:(Price.of_string "99000"))
      |> ok_exn
    in
    let%bind public = Public_ws.connect (Config.read_only other) |> ok_exn in
    let topic : Topic.t = Orderbook { depth = 50; symbol = btc } in
    let%bind () = Public_ws.subscribe public topic in
    let%bind () = Public_ws.subscribe public topic in
    let%bind () = print_messages (Public_ws.messages public) in
    [%expect
      {|
      subscribe ack success=true
      orderbook snapshot BTCUSDT bids=1 asks=0
      |}];
    (* What the venue does on a gap: a fresh snapshot. *)
    let%bind () = Public_ws.resubscribe public topic in
    let%bind () = print_messages (Public_ws.messages public) in
    [%expect
      {|
      subscribe ack success=true
      subscribe ack success=true
      orderbook snapshot BTCUSDT bids=1 asks=0
      |}];
    let%bind () = Public_ws.send public (Ping { req_id = None }) in
    let%bind () = print_messages (Public_ws.messages public) in
    [%expect {| pong op=ping |}];
    let%bind private_ = Private_ws.connect other |> ok_exn in
    print_s [%sexp (Private_ws.subscriptions private_ : Topic.t list)];
    [%expect {| ((Order ()) (Execution ()) (Position ()) Wallet) |}];
    let%bind () = print_messages (Private_ws.messages private_) in
    [%expect
      {|
      auth ack success=true
      subscribe ack success=true
      subscribe ack success=true
      subscribe ack success=true
      subscribe ack success=true
      |}];
    let%bind (_ : Order_ack.t list) = Rest.cancel_all other ~symbol:btc |> ok_exn in
    let%bind () = print_messages (Private_ws.messages private_) in
    [%expect {| order x1 |}];
    let%bind () = Public_ws.close public in
    let%bind () = Private_ws.close private_ in
    let%bind missing_key = Private_ws.connect (Config.local ()) in
    print_s [%sexp (missing_key : _ Or_error.t)];
    [%expect {| (Error "Private_ws.connect: the config has no API key") |}];
    return ())
;;
