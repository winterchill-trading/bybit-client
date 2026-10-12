open! Core
open Async
open Bybit_protocol
module Md = Market_data

let instrument symbol = Md.Instrument.create Bybit (Symbol.to_string symbol)
let time = Timestamp_ms.to_time_ns

let topic ?(l2_depth = 50) (stream : Md.Stream.t) symbol : Topic.t =
  match stream with
  | Trades -> Public_trade symbol
  | Bbo -> Orderbook { depth = 1; symbol }
  | L2 -> Orderbook { depth = l2_depth; symbol }
  | Funding -> Tickers symbol
  | Private -> raise_s [%message "Live_feed: no public topic for the private stream"]
;;

module Normalizer = struct
  module Output = struct
    type t =
      { events : Md.Event.t list
      ; resubscribe : Topic.t list
      }
    [@@deriving sexp_of]

    let empty = { events = []; resubscribe = [] }
    let events events = { events; resubscribe = [] }
  end

  (** The fields a funding record is emitted for; another one is emitted only when one of
      them changes. *)
  module Funding_key = struct
    type t =
      { rate : Decimal.t
      ; next_funding_time : Timestamp_ms.t
      ; mark : Price.t
      ; index : Price.t
      }
    [@@deriving equal]
  end

  type t =
    { books : Local_book.t String.Table.t (** by topic *)
    ; tickers : Ws_ticker.Data.t Symbol.Table.t
    ; funding : Funding_key.t Symbol.Table.t (** last emitted *)
    }

  let create () =
    { books = String.Table.create ()
    ; tickers = Symbol.Table.create ()
    ; funding = Symbol.Table.create ()
    }
  ;;

  let trades ~recv_ts (push : Public_trade.t) =
    List.map push.data ~f:(fun (trade : Public_trade.Trade.t) ->
      Md.Event.Trade
        { instrument = instrument trade.symbol
        ; exch_ts = time trade.time
        ; recv_ts
        ; price = trade.price
        ; size = trade.size
        ; side = trade.side
        ; trade_id = Exec_id.to_string trade.trade_id
        })
  ;;

  let levels (levels : Book_level.t list) =
    List.map levels ~f:(fun { price; size } : Md.L2_update.Level.t -> { price; size })
  ;;

  let bbo ~recv_ts book (push : Ws_orderbook.t) =
    match Local_book.to_l2 ~depth:1 book with
    | Some { bids = bid :: _; asks = ask :: _; _ } ->
      [ Md.Event.Bbo
          { instrument = instrument push.data.s
          ; exch_ts = time push.ts
          ; recv_ts
          ; bid_price = bid.px
          ; bid_size = bid.sz
          ; ask_price = ask.px
          ; ask_size = ask.sz
          }
      ]
    | Some _ | None -> []
  ;;

  let l2 ~recv_ts (push : Ws_orderbook.t) =
    let kind : Md.L2_update.Kind.t =
      match push.type_ with
      | Snapshot -> Snapshot
      | Delta -> Delta
    in
    let bids = levels push.data.b
    and asks = levels push.data.a in
    let bids, asks =
      match kind with
      | Delta -> bids, asks
      | Snapshot ->
        ( List.sort bids ~compare:(fun a b -> Price.compare b.price a.price)
        , List.sort asks ~compare:(fun a b -> Price.compare a.price b.price) )
    in
    [ Md.Event.L2
        { instrument = instrument push.data.s
        ; exch_ts = time push.ts
        ; recv_ts
        ; kind
        ; bids
        ; asks
        }
    ]
  ;;

  let orderbook t ~recv_ts (push : Ws_orderbook.t) : Output.t =
    let depth =
      match push.topic with
      | Orderbook { depth; _ } -> depth
      | _ -> 0
    in
    let book =
      Hashtbl.find_or_add t.books (Topic.to_string push.topic) ~default:(fun () ->
        Local_book.create push.data.s)
    in
    match Local_book.apply book push with
    | Applied ->
      Output.events (if depth = 1 then bbo ~recv_ts book push else l2 ~recv_ts push)
    | Stale | Waiting_for_snapshot -> Output.empty
    | Gap { expected; received } ->
      Log.Global.info_s
        [%message
          "bybit live feed: orderbook gap, resubscribing"
            ~topic:(Topic.to_string push.topic)
            (expected : int)
            (received : int)];
      { events = []; resubscribe = [ push.topic ] }
  ;;

  let ticker t ~recv_ts (push : Ws_ticker.t) =
    let symbol = push.data.symbol in
    let data =
      match push.type_, Hashtbl.find t.tickers symbol with
      | Delta, Some previous -> Ws_ticker.Data.apply previous ~delta:push.data
      | Snapshot, _ | Delta, None -> push.data
    in
    Hashtbl.set t.tickers ~key:symbol ~data;
    match data with
    | { funding_rate = Some rate
      ; next_funding_time = Some next_funding_time
      ; mark_price = Some mark
      ; index_price = Some index
      ; _
      } ->
      let key = { Funding_key.rate; next_funding_time; mark; index } in
      (match Hashtbl.find t.funding symbol with
       | Some last when Funding_key.equal last key -> []
       | Some _ | None ->
         Hashtbl.set t.funding ~key:symbol ~data:key;
         [ Md.Event.Funding
             { instrument = instrument symbol
             ; exch_ts = time push.ts
             ; recv_ts
             ; rate = Decimal.to_float rate
             ; next_funding_time = time next_funding_time
             ; mark_price = mark
             ; index_price = index
             }
         ])
    | _ -> []
  ;;

  let message t ~recv_ts (message : Ws_message.t) : Output.t =
    match message with
    | Public_trade push -> Output.events (trades ~recv_ts push)
    | Orderbook push -> orderbook t ~recv_ts push
    | Ticker push -> Output.events (ticker t ~recv_ts push)
    | Subscribe_ack _
    | Auth_ack _
    | Pong _
    | Op_response _
    | Order _
    | Execution _
    | Position _
    | Wallet _
    | Unknown _ -> Output.empty
  ;;

  let frame t ~recv_ts frame =
    let%bind.Or_error decoded = Ws_stream.decode frame in
    Or_error.try_with (fun () -> message t ~recv_ts decoded)
  ;;

  let reset t =
    Hashtbl.clear t.books;
    Hashtbl.clear t.tickers;
    Hashtbl.clear t.funding
  ;;
end

module Stats = struct
  type t =
    { frames : int
    ; parse_errors : int
    ; reconnects : int
    }
  [@@deriving sexp_of]
end

module Counters = struct
  type t =
    { mutable frames : int
    ; mutable parse_errors : int
    }
end

type t =
  { feed : Md.Feed.With_gaps.t
  ; streams : (Md.Stream.t * Counters.t * Public_ws.t) list
  }

let feed t = Md.Feed.With_gaps.to_feed t.feed
let feed_with_gaps t = t.feed

let stats t =
  List.map t.streams ~f:(fun (stream, (counters : Counters.t), ws) ->
    ( stream
    , { Stats.frames = counters.frames
      ; parse_errors = counters.parse_errors
      ; reconnects = Public_ws.reconnects ws
      } ))
;;

let connect
  ?on_raw
  ?l2_depth
  ?(time_source = Time_source.wall_clock ())
  config
  ~symbols
  ~streams
  =
  let streams = List.dedup_and_sort streams ~compare:Md.Stream.compare in
  if List.mem streams Private ~equal:Md.Stream.equal
  then raise_s [%message "Live_feed.create: the private stream is not a market feed"];
  let symbols = List.map symbols ~f:Symbol.of_string in
  let trades_r, trades_w = Pipe.create () in
  let bbo_r, bbo_w = Pipe.create () in
  let l2_r, l2_w = Pipe.create () in
  let funding_r, funding_w = Pipe.create () in
  let gaps_r, gaps_w = Pipe.create () in
  let gap ~recv_ts ~stream ?instrument () =
    Pipe.write_without_pushback_if_open
      gaps_w
      { Md.Gap.recv_ts; venue = Bybit; instrument; stream = Some stream; reason = Resync }
  in
  let emit : Md.Event.t -> unit = function
    | Trade x -> Pipe.write_without_pushback_if_open trades_w x
    | Bbo x -> Pipe.write_without_pushback_if_open bbo_w x
    | L2 x -> Pipe.write_without_pushback_if_open l2_w x
    | Funding x -> Pipe.write_without_pushback_if_open funding_w x
  in
  let normalizer = Normalizer.create () in
  let connect stream =
    let ws = Set_once.create () in
    let counters = { Counters.frames = 0; parse_errors = 0 } in
    (* Reconnects already reported as a gap. [on_reconnect] runs after the subscriptions
       are resent, so a frame of the new connection may arrive first; whichever comes
       first reports the gap, which then always precedes the new connection's events. *)
    let reported = ref 0 in
    let report_reconnect ~recv_ts =
      Option.iter (Set_once.get ws) ~f:(fun ws ->
        let reconnects = Public_ws.reconnects ws in
        if reconnects > !reported
        then (
          reported := reconnects;
          gap ~recv_ts ~stream ()))
    in
    let on_frame frame decoded =
      let recv_ts = Time_source.now time_source in
      counters.frames <- counters.frames + 1;
      report_reconnect ~recv_ts;
      Option.iter on_raw ~f:(fun on_raw -> on_raw ~stream ~recv_ts frame);
      match
        Or_error.bind decoded ~f:(fun message ->
          Or_error.try_with (fun () -> Normalizer.message normalizer ~recv_ts message))
      with
      | Error error ->
        counters.parse_errors <- counters.parse_errors + 1;
        Log.Global.error_s
          [%message
            "bybit live feed: cannot parse frame"
              ~stream:(Md.Stream.to_string stream)
              (frame : string)
              (error : Error.t)]
      | Ok { events; resubscribe } ->
        List.iter events ~f:emit;
        Option.iter (Set_once.get ws) ~f:(fun ws ->
          List.iter resubscribe ~f:(fun (topic : Topic.t) ->
            (match topic with
             | Orderbook { symbol; _ } | Public_trade symbol | Tickers symbol ->
               gap ~recv_ts ~stream ~instrument:(instrument symbol) ()
             | _ -> gap ~recv_ts ~stream ());
            don't_wait_for (Public_ws.resubscribe ws topic)))
    in
    let on_reconnect () =
      report_reconnect ~recv_ts:(Time_source.now time_source);
      Log.Global.info "bybit live feed: %s reconnected" (Md.Stream.to_string stream)
    in
    let%bind connection =
      Public_ws.connect ~on_reconnect ~on_frame ~time_source config >>| Or_error.ok_exn
    in
    Set_once.set_exn ws connection;
    (* Frames are handled in [on_frame]; nobody reads the pipe. *)
    Pipe.close_read (Public_ws.messages connection);
    let%map () =
      Deferred.List.iter symbols ~how:`Sequential ~f:(fun symbol ->
        Public_ws.subscribe connection (topic ?l2_depth stream symbol))
    in
    stream, counters, connection
  in
  let opened = ref [] in
  let close_all () =
    Deferred.List.iter !opened ~how:`Parallel ~f:(fun (_, _, ws) -> Public_ws.close ws)
  in
  let%bind () =
    match%bind
      Monitor.try_with (fun () ->
        Deferred.List.iter streams ~how:`Sequential ~f:(fun stream ->
          let%map connection = connect stream in
          opened := connection :: !opened))
    with
    | Ok () -> return ()
    | Error exn ->
      let%map () = close_all () in
      raise exn
  in
  let closed =
    Lazy_deferred.create (fun () ->
      let%map () = close_all () in
      Pipe.close trades_w;
      Pipe.close bbo_w;
      Pipe.close l2_w;
      Pipe.close funding_w;
      Pipe.close gaps_w)
  in
  let feed : Md.Feed.With_gaps.t =
    (module struct
      let trades = trades_r
      let bbo = bbo_r
      let l2 = l2_r
      let funding = funding_r
      let gaps = gaps_r
      let close () = Lazy_deferred.force_exn closed
    end)
  in
  return { feed; streams = List.rev !opened }
;;

let create ?on_raw ?l2_depth config ~symbols ~streams =
  let%map t = connect ?on_raw ?l2_depth (Config.read_only config) ~symbols ~streams in
  feed t
;;
