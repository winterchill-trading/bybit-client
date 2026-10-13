open! Core
open Bybit_protocol

module Outcome = struct
  type t =
    | Applied
    | Stale
    | Waiting_for_snapshot
    | Gap of
        { expected : int
        ; received : int
        }
  [@@deriving sexp_of, equal]
end

type t =
  { symbol : Symbol.t
  ; mutable synced : bool
  ; mutable update_id : int option
  ; mutable time_ms : int
  ; mutable bids : Size.t Price.Map.t
  ; mutable asks : Size.t Price.Map.t
  }

let create symbol =
  { symbol
  ; synced = false
  ; update_id = None
  ; time_ms = 0
  ; bids = Price.Map.empty
  ; asks = Price.Map.empty
  }
;;

let symbol t = t.symbol
let is_synced t = t.synced
let update_id t = if t.synced then t.update_id else None

let apply_levels map levels =
  List.fold levels ~init:map ~f:(fun map ({ price; size } : Book_level.t) ->
    if Size.is_zero size then Map.remove map price else Map.set map ~key:price ~data:size)
;;

let reset t =
  t.synced <- false;
  t.update_id <- None;
  t.bids <- Price.Map.empty;
  t.asks <- Price.Map.empty
;;

let wrong_symbol t push =
  raise_s
    [%message
      "Local_book.apply: wrong symbol" ~book:(t.symbol : Symbol.t) ~push:(push : Symbol.t)]
;;

(* The update rules shared by [apply] and [apply_scan]; [bids] and [asks] apply the push's
   levels to a side. *)
let update t ~snapshot ~u ~ts_ms ~bids ~asks : Outcome.t =
  if snapshot
  then (
    t.bids <- bids Price.Map.empty;
    t.asks <- asks Price.Map.empty;
    t.synced <- true;
    t.update_id <- Some u;
    t.time_ms <- ts_ms;
    Applied)
  else (
    match t.synced, t.update_id with
    | false, _ | true, None -> Waiting_for_snapshot
    | true, Some previous ->
      if u <= previous
      then Stale
      else if u <> previous + 1
      then (
        reset t;
        Gap { expected = previous + 1; received = u })
      else (
        t.bids <- bids t.bids;
        t.asks <- asks t.asks;
        t.update_id <- Some u;
        t.time_ms <- ts_ms;
        Applied))
;;

let apply t ({ type_; ts; data; _ } : Ws_orderbook.t) : Outcome.t =
  if not (Symbol.equal data.s t.symbol) then wrong_symbol t data.s;
  update
    t
    ~snapshot:
      (match type_ with
       | Snapshot -> true
       | Delta -> false)
    ~u:data.u
    ~ts_ms:(Timestamp_ms.to_int_ms ts)
    ~bids:(fun map -> apply_levels map data.b)
    ~asks:(fun map -> apply_levels map data.a)
;;

let apply_scanned_levels map n ~price ~size =
  let mutable map = map in
  for i = 0 to n - 1 do
    let size = Size.of_units (size i) in
    let price = Price.of_units (price i) in
    map
    <- (if Size.is_zero size
        then Map.remove map price
        else Map.set map ~key:price ~data:size)
  done;
  map
;;

let apply_scan t ~frame scan =
  if not
       (Frame_scan.equal_sub
          frame
          ~pos:(Frame_scan.symbol_pos scan)
          ~len:(Frame_scan.symbol_len scan)
          (Symbol.to_string t.symbol))
  then
    wrong_symbol
      t
      (Symbol.of_string
         (String.sub
            frame
            ~pos:(Frame_scan.symbol_pos scan)
            ~len:(Frame_scan.symbol_len scan)));
  update
    t
    ~snapshot:(Frame_scan.snapshot scan)
    ~u:(Frame_scan.update_id scan)
    ~ts_ms:(Frame_scan.ts scan)
    ~bids:(fun map ->
      apply_scanned_levels
        map
        (Frame_scan.bids scan)
        ~price:(Frame_scan.bid_price scan)
        ~size:(Frame_scan.bid_size scan))
    ~asks:(fun map ->
      apply_scanned_levels
        map
        (Frame_scan.asks scan)
        ~price:(Frame_scan.ask_price scan)
        ~size:(Frame_scan.ask_size scan))
;;

let best_bid t = if t.synced then Map.max_elt t.bids else None
let best_ask t = if t.synced then Map.min_elt t.asks else None

let to_l2 ?depth t : Exchange_core.L2.t option =
  if not t.synced
  then None
  else (
    let side map ~order =
      let levels = Map.to_alist ~key_order:order map in
      let levels =
        match depth with
        | None -> levels
        | Some depth -> List.take levels depth
      in
      List.map levels ~f:(fun (px, sz) -> { Exchange_core.L2.Level.px; sz; n = 0 })
    in
    Some
      { symbol = t.symbol
      ; time = t.time_ms * 1_000_000
      ; bids = side t.bids ~order:`Decreasing
      ; asks = side t.asks ~order:`Increasing
      })
;;
