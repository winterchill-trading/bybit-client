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

  (** One subscribed topic, with what every event of it needs, built once: the topic
      string, its symbol and instrument, and its local book. *)
  module Subscription = struct
    type t =
      { topic : Topic.t
      ; symbol : Symbol.t
      ; symbol_string : string
      ; instrument : Md.Instrument.t
      ; mutable book : Local_book.t option
      }

    let create (topic : Topic.t) =
      match topic with
      | Orderbook { symbol; _ } | Public_trade symbol | Tickers symbol ->
        Some
          { topic
          ; symbol
          ; symbol_string = Symbol.to_string symbol
          ; instrument = instrument symbol
          ; book = None
          }
      | Order _ | Execution _ | Position _ | Wallet | Other _ -> None
    ;;

    (* The topic's instrument when [symbol] is the topic's own symbol. *)
    let instrument_for t symbol =
      if Symbol.equal symbol t.symbol then t.instrument else instrument symbol
    ;;
  end

  type t =
    { mutable subscriptions : Subscription.t list (** one per topic *)
    ; mutable aliases : (string * Subscription.t) list
    (** topic strings as received, for lookups without allocating *)
    ; tickers : Ws_ticker.Data.t Symbol.Table.t
    ; funding : Funding_key.t Symbol.Table.t (** last emitted *)
    ; scan : Frame_scan.t
    }

  let create () =
    { subscriptions = []
    ; aliases = []
    ; tickers = Symbol.Table.create ()
    ; funding = Symbol.Table.create ()
    ; scan = Frame_scan.create ()
    }
  ;;

  let subscription t topic =
    match
      List.find t.subscriptions ~f:(fun (s : Subscription.t) -> Topic.equal s.topic topic)
    with
    | Some _ as found -> found
    | None ->
      let created = Subscription.create topic in
      Option.iter created ~f:(fun s -> t.subscriptions <- s :: t.subscriptions);
      created
  ;;

  (* The subscription of the topic string at [pos], [len] in [frame]; allocates only the
     first time a topic string is seen. *)
  let subscription_of_span t frame ~pos ~len =
    let rec find = function
      | [] -> None
      | (alias, s) :: rest ->
        if Frame_scan.equal_sub frame ~pos ~len alias then Some s else find rest
    in
    match find t.aliases with
    | Some _ as found -> found
    | None ->
      let alias = String.sub frame ~pos ~len in
      let found = subscription t (Topic.of_string alias) in
      Option.iter found ~f:(fun s -> t.aliases <- (alias, s) :: t.aliases);
      found
  ;;

  let book (subscription : Subscription.t) ~symbol =
    match subscription.book with
    | Some book -> book
    | None ->
      let book = Local_book.create symbol in
      subscription.book <- Some book;
      book
  ;;

  let trades t ~recv_ts (push : Public_trade.t) =
    let subscription = subscription t push.topic in
    List.map push.data ~f:(fun (trade : Public_trade.Trade.t) ->
      Md.Event.Trade
        { instrument =
            (match subscription with
             | Some s -> Subscription.instrument_for s trade.symbol
             | None -> instrument trade.symbol)
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

  let bbo ~recv_ts ~instrument ~ts book =
    match Local_book.best_bid book, Local_book.best_ask book with
    | Some (bid_price, bid_size), Some (ask_price, ask_size) ->
      [ Md.Event.Bbo
          { instrument
          ; exch_ts = time ts
          ; recv_ts
          ; bid_price
          ; bid_size
          ; ask_price
          ; ask_size
          }
      ]
    | _ -> []
  ;;

  let l2_event ~recv_ts ~instrument ~ts ~snapshot ~bids ~asks =
    let kind : Md.L2_update.Kind.t = if snapshot then Snapshot else Delta in
    let bids, asks =
      match kind with
      | Delta -> bids, asks
      | Snapshot ->
        ( List.sort bids ~compare:(fun (a : Md.L2_update.Level.t) b ->
            Price.compare b.price a.price)
        , List.sort asks ~compare:(fun (a : Md.L2_update.Level.t) b ->
            Price.compare a.price b.price) )
    in
    [ Md.Event.L2 { instrument; exch_ts = time ts; recv_ts; kind; bids; asks } ]
  ;;

  let book_outcome
    (subscription : Subscription.t)
    ~(outcome : Local_book.Outcome.t)
    ~depth
    ~bbo
    ~l2
    : Output.t
    =
    match outcome with
    | Applied -> Output.events (if depth = 1 then bbo () else l2 ())
    | Stale | Waiting_for_snapshot -> Output.empty
    | Gap { expected; received } ->
      Log.Global.info_s
        [%message
          "bybit live feed: orderbook gap, resubscribing"
            ~topic:(Topic.to_string subscription.topic)
            (expected : int)
            (received : int)];
      { events = []; resubscribe = [ subscription.topic ] }
  ;;

  let orderbook t ~recv_ts (push : Ws_orderbook.t) : Output.t =
    let depth =
      match push.topic with
      | Orderbook { depth; _ } -> depth
      | _ -> 0
    in
    match subscription t push.topic with
    | None -> Output.empty
    | Some subscription ->
      let book = book subscription ~symbol:push.data.s in
      let instrument = Subscription.instrument_for subscription push.data.s in
      book_outcome
        subscription
        ~outcome:(Local_book.apply book push)
        ~depth
        ~bbo:(fun () -> bbo ~recv_ts ~instrument ~ts:push.ts book)
        ~l2:(fun () ->
          l2_event
            ~recv_ts
            ~instrument
            ~ts:push.ts
            ~snapshot:
              (match push.type_ with
               | Snapshot -> true
               | Delta -> false)
            ~bids:(levels push.data.b)
            ~asks:(levels push.data.a))
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
             { instrument =
                 (match subscription t push.topic with
                  | Some s -> Subscription.instrument_for s symbol
                  | None -> instrument symbol)
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
    | Public_trade push -> Output.events (trades t ~recv_ts push)
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

  let scanned_trades t ~recv_ts ~frame (subscription : Subscription.t) =
    let scan = t.scan in
    let n = Frame_scan.trades scan in
    let rec same_symbol i =
      i >= n
      || (Frame_scan.equal_sub
            frame
            ~pos:(Frame_scan.trade_symbol_pos scan i)
            ~len:(Frame_scan.trade_symbol_len scan i)
            subscription.symbol_string
          && same_symbol (i + 1))
    in
    if not (same_symbol 0)
    then None
    else
      Some
        (Output.events
           (List.init n ~f:(fun i ->
              Md.Event.Trade
                { instrument = subscription.instrument
                ; exch_ts = time (Timestamp_ms.of_int_ms (Frame_scan.trade_time scan i))
                ; recv_ts
                ; price = Price.of_units (Frame_scan.trade_price scan i)
                ; size = Size.of_units (Frame_scan.trade_size scan i)
                ; side = (if Frame_scan.trade_buy scan i then Buy else Sell)
                ; trade_id =
                    String.sub
                      frame
                      ~pos:(Frame_scan.trade_id_pos scan i)
                      ~len:(Frame_scan.trade_id_len scan i)
                })))
  ;;

  let scanned_levels n ~price ~size =
    List.init n ~f:(fun i : Md.L2_update.Level.t ->
      { price = Price.of_units (price i); size = Size.of_units (size i) })
  ;;

  let scanned_book t ~recv_ts ~frame ~depth (subscription : Subscription.t) =
    let scan = t.scan in
    if not
         (Frame_scan.equal_sub
            frame
            ~pos:(Frame_scan.symbol_pos scan)
            ~len:(Frame_scan.symbol_len scan)
            subscription.symbol_string)
    then None
    else (
      let book = book subscription ~symbol:subscription.symbol in
      let instrument = subscription.instrument in
      let ts = Timestamp_ms.of_int_ms (Frame_scan.ts scan) in
      Some
        (book_outcome
           subscription
           ~outcome:(Local_book.apply_scan book ~frame scan)
           ~depth
           ~bbo:(fun () -> bbo ~recv_ts ~instrument ~ts book)
           ~l2:(fun () ->
             l2_event
               ~recv_ts
               ~instrument
               ~ts
               ~snapshot:(Frame_scan.snapshot scan)
               ~bids:
                 (scanned_levels
                    (Frame_scan.bids scan)
                    ~price:(Frame_scan.bid_price scan)
                    ~size:(Frame_scan.bid_size scan))
               ~asks:
                 (scanned_levels
                    (Frame_scan.asks scan)
                    ~price:(Frame_scan.ask_price scan)
                    ~size:(Frame_scan.ask_size scan)))))
  ;;

  let scan t ~recv_ts frame =
    if not (Frame_scan.scan t.scan frame)
    then None
    else (
      match
        subscription_of_span
          t
          frame
          ~pos:(Frame_scan.topic_pos t.scan)
          ~len:(Frame_scan.topic_len t.scan)
      with
      | None -> None
      | Some subscription ->
        (match Frame_scan.kind t.scan, subscription.topic with
         | Trades, Public_trade _ -> scanned_trades t ~recv_ts ~frame subscription
         | Book, Orderbook { depth; _ } ->
           scanned_book t ~recv_ts ~frame ~depth subscription
         | (Trades | Book), _ -> None))
  ;;

  let decode_frame t ~recv_ts frame =
    let%bind.Or_error decoded = Ws_stream.decode frame in
    Or_error.try_with (fun () -> message t ~recv_ts decoded)
  ;;

  let frame t ~recv_ts frame =
    match scan t ~recv_ts frame with
    | Some output -> Ok output
    | None -> decode_frame t ~recv_ts frame
    | exception exn -> Error (Error.of_exn exn)
  ;;

  let reset t =
    t.subscriptions <- [];
    t.aliases <- [];
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
    (* [intercept] runs first for every frame; [on_frame] only for frames the scanner left
       to the Yojson decoder, right after [intercept], so it reuses its [recv_ts]. *)
    let last_recv_ts = ref Time_ns.epoch in
    let handle frame ~recv_ts (output : Normalizer.Output.t Or_error.t) =
      match output with
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
    let intercept frame =
      let recv_ts = Time_source.now time_source in
      last_recv_ts := recv_ts;
      counters.frames <- counters.frames + 1;
      report_reconnect ~recv_ts;
      Option.iter on_raw ~f:(fun on_raw -> on_raw ~stream ~recv_ts frame);
      match Normalizer.scan normalizer ~recv_ts frame with
      | None -> false
      | Some output ->
        handle frame ~recv_ts (Ok output);
        true
      | exception exn ->
        handle frame ~recv_ts (Error (Error.of_exn exn));
        true
    in
    let on_frame frame decoded =
      let recv_ts = !last_recv_ts in
      handle
        frame
        ~recv_ts
        (Or_error.bind decoded ~f:(fun message ->
           Or_error.try_with (fun () -> Normalizer.message normalizer ~recv_ts message)))
    in
    let on_reconnect () =
      report_reconnect ~recv_ts:(Time_source.now time_source);
      Log.Global.info "bybit live feed: %s reconnected" (Md.Stream.to_string stream)
    in
    let%bind connection =
      Public_ws.connect ~on_reconnect ~intercept ~on_frame ~time_source config
      >>| Or_error.ok_exn
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
