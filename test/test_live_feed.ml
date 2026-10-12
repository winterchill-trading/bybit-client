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
  [%expect
    {|
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

let%expect_test "orderbook.50: snapshot, delta, gap" =
  feed
    (normalizer ())
    [ (* a delta before any snapshot is dropped *)
      {|{"topic":"orderbook.50.BTCUSDT","type":"delta","ts":1672304484977,
         "data":{"s":"BTCUSDT","b":[["16493.50","1"]],"a":[],"u":18521287,"seq":7961638723},
         "cts":1672304484975}|}
    ; {|{"topic":"orderbook.50.BTCUSDT","type":"snapshot","ts":1672304484978,
         "data":{"s":"BTCUSDT","b":[["16493.00","0.100"],["16493.50","0.006"]],
                 "a":[["16612.00","0.213"],["16611.00","0.029"]],
                 "u":18521288,"seq":7961638724},
         "cts":1672304484976}|}
    ; {|{"topic":"orderbook.50.BTCUSDT","type":"delta","ts":1672304484990,
         "data":{"s":"BTCUSDT","b":[["16493.50","0"],["16494.00","0.5"]],
                 "a":[["16611.00","0.040"]],"u":18521289,"seq":7961638725},
         "cts":1672304484988}|}
    ; (* u skips 18521290 *)
      {|{"topic":"orderbook.50.BTCUSDT","type":"delta","ts":1672304485000,
         "data":{"s":"BTCUSDT","b":[],"a":[["16612.00","0"]],"u":18521291,"seq":7961638727},
         "cts":1672304484998}|}
    ; (* ignored until the next snapshot *)
      {|{"topic":"orderbook.50.BTCUSDT","type":"delta","ts":1672304485010,
         "data":{"s":"BTCUSDT","b":[],"a":[["16613.00","1"]],"u":18521292,"seq":7961638728},
         "cts":1672304485008}|}
    ];
  [%expect
    {|
    no events
    ((events
      ((L2
        ((instrument ((venue Bybit) (symbol BTCUSDT)))
         (exch_ts "2022-12-29 09:01:24.978000000Z")
         (recv_ts "2026-10-12 12:00:00.000000000Z") (kind Snapshot)
         (bids (((price 16493.5) (size 0.006)) ((price 16493) (size 0.1))))
         (asks (((price 16611) (size 0.029)) ((price 16612) (size 0.213))))))))
     (resubscribe ()))
    ((events
      ((L2
        ((instrument ((venue Bybit) (symbol BTCUSDT)))
         (exch_ts "2022-12-29 09:01:24.990000000Z")
         (recv_ts "2026-10-12 12:00:00.000000000Z") (kind Delta)
         (bids (((price 16493.5) (size 0)) ((price 16494) (size 0.5))))
         (asks (((price 16611) (size 0.04))))))))
     (resubscribe ()))
    ((events ()) (resubscribe ((Orderbook (depth 50) (symbol BTCUSDT)))))
    no events
    |}]
;;

let%expect_test "orderbook.1 becomes bbo" =
  feed
    (normalizer ())
    [ {|{"topic":"orderbook.1.ETHUSDT","type":"snapshot","ts":1672304484978,
         "data":{"s":"ETHUSDT","b":[["1200.10","3.5"]],"a":[["1200.20","1.25"]],
                 "u":901,"seq":51},
         "cts":1672304484976}|}
    ; {|{"topic":"orderbook.1.ETHUSDT","type":"snapshot","ts":1672304485078,
         "data":{"s":"ETHUSDT","b":[["1200.15","0.5"]],"a":[["1200.20","1"]],
                 "u":902,"seq":52},
         "cts":1672304485076}|}
    ; (* one side empty: no bbo *)
      {|{"topic":"orderbook.1.ETHUSDT","type":"snapshot","ts":1672304485178,
         "data":{"s":"ETHUSDT","b":[],"a":[["1200.20","1"]],"u":903,"seq":53},
         "cts":1672304485176}|}
    ];
  [%expect
    {|
    ((events
      ((Bbo
        ((instrument ((venue Bybit) (symbol ETHUSDT)))
         (exch_ts "2022-12-29 09:01:24.978000000Z")
         (recv_ts "2026-10-12 12:00:00.000000000Z") (bid_price 1200.1)
         (bid_size 3.5) (ask_price 1200.2) (ask_size 1.25)))))
     (resubscribe ()))
    ((events
      ((Bbo
        ((instrument ((venue Bybit) (symbol ETHUSDT)))
         (exch_ts "2022-12-29 09:01:25.078000000Z")
         (recv_ts "2026-10-12 12:00:00.000000000Z") (bid_price 1200.15)
         (bid_size 0.5) (ask_price 1200.2) (ask_size 1)))))
     (resubscribe ()))
    no events
    |}]
;;

let%expect_test "tickers become funding when it changes" =
  feed
    (normalizer ())
    [ {|{"topic":"tickers.BTCUSDT","type":"snapshot","data":{
         "symbol":"BTCUSDT","tickDirection":"MinusTick","price24hPcnt":"-0.158315",
         "lastPrice":"66666.60","prevPrice24h":"79206.20","highPrice24h":"79266.30",
         "lowPrice24h":"65076.90","prevPrice1h":"66666.60","markPrice":"66666.60",
         "indexPrice":"115418.19","openInterest":"492373.72",
         "openInterestValue":"32824881841.75","turnover24h":"4936790807.6521",
         "volume24h":"73191.3870","fundingIntervalHour":"8","fundingCap":"0.005",
         "nextFundingTime":"1760342400000","fundingRate":"-0.005","bid1Price":"66666.60",
         "bid1Size":"23789.165","ask1Price":"66666.70","ask1Size":"23775.469",
         "preOpenPrice":"","preQty":"","curPreListingPhase":""},
         "cs":9532239429,"ts":1760325052630}|}
    ; (* only the book moved *)
      {|{"topic":"tickers.BTCUSDT","type":"delta","data":{
         "symbol":"BTCUSDT","bid1Price":"66666.50","bid1Size":"1.5"},
         "cs":9532239430,"ts":1760325052730}|}
    ; {|{"topic":"tickers.BTCUSDT","type":"delta","data":{
         "symbol":"BTCUSDT","markPrice":"66670.00","fundingRate":"-0.0049"},
         "cs":9532239431,"ts":1760325052830}|}
    ];
  [%expect {|
    ((events
      ((Funding
        ((instrument ((venue Bybit) (symbol BTCUSDT)))
         (exch_ts "2025-10-13 03:10:52.630000000Z")
         (recv_ts "2026-10-12 12:00:00.000000000Z") (rate -0.005)
         (next_funding_time "2025-10-13 08:00:00.000000000Z")
         (mark_price 66666.6) (index_price 115418.19)))))
     (resubscribe ()))
    no events
    ((events
      ((Funding
        ((instrument ((venue Bybit) (symbol BTCUSDT)))
         (exch_ts "2025-10-13 03:10:52.830000000Z")
         (recv_ts "2026-10-12 12:00:00.000000000Z") (rate -0.0049)
         (next_funding_time "2025-10-13 08:00:00.000000000Z") (mark_price 66670)
         (index_price 115418.19)))))
     (resubscribe ()))
    |}]
;;

let%expect_test "acks, pongs and junk" =
  feed
    (normalizer ())
    [ {|{"success":true,"ret_msg":"","conn_id":"c1","req_id":"","op":"subscribe"}|}
    ; {|{"success":true,"ret_msg":"pong","conn_id":"c1","req_id":"","op":"ping"}|}
    ; {|{"topic":"kline.1.BTCUSDT","type":"snapshot","ts":1,"data":[]}|}
    ; {|not json|}
    ];
  [%expect {|
    no events
    no events
    no events
    parse error
    |}]
;;
