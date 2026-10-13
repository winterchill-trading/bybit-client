open! Core
open Bybit_client

let show scan frame =
  if not (Frame_scan.scan scan frame)
  then print_endline "fallback"
  else (
    let sub pos len = String.sub frame ~pos ~len in
    let topic = sub (Frame_scan.topic_pos scan) (Frame_scan.topic_len scan) in
    match Frame_scan.kind scan with
    | Book ->
      let side n price size = List.init n ~f:(fun i -> price scan i, size scan i) in
      print_s
        [%message
          topic
            ~snapshot:(Frame_scan.snapshot scan : bool)
            ~ts:(Frame_scan.ts scan : int)
            ~symbol:
              (sub (Frame_scan.symbol_pos scan) (Frame_scan.symbol_len scan) : string)
            ~u:(Frame_scan.update_id scan : int)
            ~bids:
              (side (Frame_scan.bids scan) Frame_scan.bid_price Frame_scan.bid_size
               : (int * int) list)
            ~asks:
              (side (Frame_scan.asks scan) Frame_scan.ask_price Frame_scan.ask_size
               : (int * int) list)]
    | Trades ->
      let trades =
        List.init (Frame_scan.trades scan) ~f:(fun i ->
          [%message
            ""
              ~time:(Frame_scan.trade_time scan i : int)
              ~symbol:
                (sub
                   (Frame_scan.trade_symbol_pos scan i)
                   (Frame_scan.trade_symbol_len scan i)
                 : string)
              ~buy:(Frame_scan.trade_buy scan i : bool)
              ~price:(Frame_scan.trade_price scan i : int)
              ~size:(Frame_scan.trade_size scan i : int)
              ~id:
                (sub (Frame_scan.trade_id_pos scan i) (Frame_scan.trade_id_len scan i)
                 : string)])
      in
      print_s [%message topic ~ts:(Frame_scan.ts scan : int) (trades : Sexp.t list)])
;;

let%expect_test "orderbook and trade frames" =
  let scan = Frame_scan.create () in
  show
    scan
    {|{"topic":"orderbook.1.BTCUSDT","ts":17,"type":"snapshot","data":{"s":"BTCUSDT","b":[["82597.2","2.614"]],"a":[["82597.3","3.784"]],"u":119,"seq":824},"cts":16}|};
  [%expect
    {|
    (orderbook.1.BTCUSDT (snapshot true) (ts 17) (symbol BTCUSDT) (u 119)
     (bids ((8259720000000 261400000))) (asks ((8259730000000 378400000))))
    |}];
  show
    scan
    {| { "topic" : "orderbook.50.BTCUSDT", "type":"delta", "ts":18,
        "data": {"s":"BTCUSDT","b":[],"a":[["1","0"], ["0.123456789","10"]],"u":120,"seq":825,"x":{"y":["]"]}} } |};
  [%expect
    {|
    (orderbook.50.BTCUSDT (snapshot false) (ts 18) (symbol BTCUSDT) (u 120)
     (bids ()) (asks ((100000000 0) (12345678 1000000000))))
    |}];
  show
    scan
    {|{"topic":"publicTrade.BTCUSDT","type":"snapshot","ts":19,"data":[{"T":18,"s":"BTCUSDT","S":"Sell","v":"0.001","p":"82597.20","L":"MinusTick","i":"b212","BT":false,"RPI":false,"seq":82},{"T":19,"s":"BTCUSDT","S":"Buy","v":"1","p":"2","i":"c"}]}|};
  [%expect
    {|
    (publicTrade.BTCUSDT (ts 19)
     (trades
      (((time 18) (symbol BTCUSDT) (buy false) (price 8259720000000)
        (size 100000) (id b212))
       ((time 19) (symbol BTCUSDT) (buy true) (price 200000000) (size 100000000)
        (id c)))))
    |}]
;;

let%expect_test "shapes left to the Yojson decoder" =
  let scan = Frame_scan.create ~capacity:2 () in
  List.iter
    ~f:(show scan)
    [ (* acknowledgement *)
      {|{"success":true,"ret_msg":"","op":"subscribe"}|}
    ; (* another topic *)
      {|{"topic":"tickers.BTCUSDT","type":"snapshot","ts":1,"data":{"symbol":"BTCUSDT"}}|}
    ; (* topic and data disagree *)
      {|{"topic":"orderbook.1.BTCUSDT","type":"snapshot","ts":1,"data":[]}|}
    ; (* string timestamp *)
      {|{"topic":"publicTrade.X","type":"snapshot","ts":"1","data":[]}|}
    ; (* escaped string *)
      {|{"topic":"publicTrade.X","type":"snapshot","ts":1,"data":[{"T":1,"s":"X","S":"Buy","v":"1","p":"1","i":"a\"b"}]}|}
    ; (* exponent, negative, missing digits, too many integer digits *)
      {|{"topic":"orderbook.1.X","type":"delta","ts":1,"data":{"s":"X","b":[["1e3","1"]],"a":[],"u":1,"seq":1}}|}
    ; {|{"topic":"orderbook.1.X","type":"delta","ts":1,"data":{"s":"X","b":[["-1","1"]],"a":[],"u":1,"seq":1}}|}
    ; {|{"topic":"orderbook.1.X","type":"delta","ts":1,"data":{"s":"X","b":[["1.","1"]],"a":[],"u":1,"seq":1}}|}
    ; {|{"topic":"orderbook.1.X","type":"delta","ts":1,"data":{"s":"X","b":[["12345678901","1"]],"a":[],"u":1,"seq":1}}|}
    ; (* missing seq *)
      {|{"topic":"orderbook.1.X","type":"delta","ts":1,"data":{"s":"X","b":[],"a":[],"u":1}}|}
    ; (* over capacity *)
      {|{"topic":"orderbook.1.X","type":"delta","ts":1,"data":{"s":"X","b":[["1","1"],["2","1"],["3","1"]],"a":[],"u":1,"seq":1}}|}
    ; (* unknown type, trailing garbage, truncated *)
      {|{"topic":"orderbook.1.X","type":"partial","ts":1,"data":{"s":"X","b":[],"a":[],"u":1,"seq":1}}|}
    ; {|{"topic":"orderbook.1.X","type":"delta","ts":1,"data":{"s":"X","b":[],"a":[],"u":1,"seq":1}} x|}
    ; {|{"topic":"orderbook.1.X","type":"delta","ts":1,"data":{"s":"X","b":[],"a":[],"u":1,|}
    ; ""
    ];
  [%expect
    {|
    fallback
    fallback
    fallback
    fallback
    fallback
    fallback
    fallback
    fallback
    fallback
    fallback
    fallback
    fallback
    fallback
    fallback
    fallback
    |}]
;;

let%expect_test "no allocation per frame" =
  let scan = Frame_scan.create () in
  List.iter [ "trades"; "bbo"; "l2" ] ~f:(fun stream ->
    let frames = In_channel.read_lines ("fixtures/" ^ stream ^ ".jsonl") in
    let scanned = ref 0 in
    let before = Gc.minor_words () in
    List.iter frames ~f:(fun frame -> if Frame_scan.scan scan frame then incr scanned);
    let words = Gc.minor_words () - before in
    print_s
      [%message
        stream ~frames:(List.length frames : int) ~scanned:(!scanned : int) (words : int)]);
  [%expect
    {|
    (trades (frames 225) (scanned 224) (words 0))
    (bbo (frames 580) (scanned 579) (words 0))
    (l2 (frames 851) (scanned 850) (words 0))
    |}]
;;
