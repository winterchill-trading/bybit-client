open! Core
open Bybit_client

let recv_ts = Time_ns.of_string_with_utc_offset "2026-10-12 12:00:00.000000000Z"
let normalizer = Live_feed.Normalizer.create

(* Time_ns sexps use the local zone; print UTC so the output does not depend on the
   machine. *)
let rec utc (sexp : Sexp.t) : Sexp.t =
  match sexp with
  | List [ Atom _; Atom _ ] ->
    (match Option.try_with (fun () -> Time_ns.t_of_sexp sexp) with
     | Some time -> Atom (Time_ns.to_string_utc time)
     | None -> sexp)
  | List sexps -> List (List.map sexps ~f:utc)
  | Atom _ -> sexp
;;

let feed t frames =
  List.iter frames ~f:(fun frame ->
    match Live_feed.Normalizer.frame t ~recv_ts frame with
    | Error _ -> print_endline "parse error"
    | Ok { events = []; resubscribe = [] } -> print_endline "no events"
    | Ok output -> print_s (utc [%sexp (output : Live_feed.Normalizer.Output.t)]))
;;

let%expect_test "public trades" =
  feed
    (normalizer ())
    [ {|{"topic":"publicTrade.BTCUSDT","type":"snapshot","ts":1672304486868,"data":[
        {"T":1672304486865,"s":"BTCUSDT","S":"Buy","v":"0.001","p":"16578.50","L":"PlusTick",
         "i":"20f43950-d8dd-5b31-9112-a178eb6023af","BT":false,"seq":1783284617},
        {"T":1672304486866,"s":"BTCUSDT","S":"Sell","v":"0.25","p":"16578.00","L":"MinusTick",
         "i":"5c2a3d7e-0b1f-5a43-8f3e-6c9d2b1a0e44","BT":false,"seq":1783284618}]}|}
    ];
  [%expect {|
    ((events
      ((Trade
        ((instrument ((venue Bybit) (symbol BTCUSDT)))
         (exch_ts "2022-12-29 09:01:26.865000000Z")
         (recv_ts "2026-10-12 12:00:00.000000000Z") (price 16578.5) (size 0.001)
         (side Buy) (trade_id 20f43950-d8dd-5b31-9112-a178eb6023af)))
       (Trade
        ((instrument ((venue Bybit) (symbol BTCUSDT)))
         (exch_ts "2022-12-29 09:01:26.866000000Z")
         (recv_ts "2026-10-12 12:00:00.000000000Z") (price 16578) (size 0.25)
         (side Sell) (trade_id 5c2a3d7e-0b1f-5a43-8f3e-6c9d2b1a0e44)))))
     (resubscribe ()))
    |}]
;;
