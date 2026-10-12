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

let apply t ({ type_; ts; data; _ } : Ws_orderbook.t) : Outcome.t =
  if not (Symbol.equal data.s t.symbol)
  then
    raise_s
      [%message
        "Local_book.apply: wrong symbol"
          ~book:(t.symbol : Symbol.t)
          ~push:(data.s : Symbol.t)];
  match type_ with
  | Snapshot ->
    t.bids <- apply_levels Price.Map.empty data.b;
    t.asks <- apply_levels Price.Map.empty data.a;
    t.synced <- true;
    t.update_id <- Some data.u;
    t.time_ms <- Timestamp_ms.to_int_ms ts;
    Applied
  | Delta ->
    (match t.synced, t.update_id with
     | false, _ | true, None -> Waiting_for_snapshot
     | true, Some previous ->
       if data.u <= previous
       then Stale
       else if data.u <> previous + 1
       then (
         reset t;
         Gap { expected = previous + 1; received = data.u })
       else (
         t.bids <- apply_levels t.bids data.b;
         t.asks <- apply_levels t.asks data.a;
         t.update_id <- Some data.u;
         t.time_ms <- Timestamp_ms.to_int_ms ts;
         Applied))
;;

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
