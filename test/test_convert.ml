open! Core
open Bybit_protocol
open Bybit_client

let%expect_test "id mapping" =
  let ids = Id_map.create () in
  let order s = Id_map.order_id ids (Order_id.of_string s) in
  let show s =
    let id = order s in
    printf
      "%s -> %s -> %s\n"
      s
      (Exchange_core.Order_id.to_string id)
      (Option.value_map
         (Id_map.to_bybit_order_id ids id)
         ~default:"?"
         ~f:Order_id.to_string)
  in
  List.iter
    [ "1"
    ; "1321003749386327552"
    ; "fd4300ae-7847-404e-b947-b46980a4d140"
    ; "00000000-0000-4000-8000-000000000001"
    ; "fd4300ae-7847-404e-b947-b46980a4d140"
    ; "99999999999999999999"
    ]
    ~f:show;
  [%expect
    {|
    1 -> 1 -> 1
    1321003749386327552 -> 1321003749386327552 -> 1321003749386327552
    fd4300ae-7847-404e-b947-b46980a4d140 -> -1 -> fd4300ae-7847-404e-b947-b46980a4d140
    00000000-0000-4000-8000-000000000001 -> -2 -> 00000000-0000-4000-8000-000000000001
    fd4300ae-7847-404e-b947-b46980a4d140 -> -1 -> fd4300ae-7847-404e-b947-b46980a4d140
    99999999999999999999 -> -3 -> 99999999999999999999
    |}];
  print_s
    [%sexp
      (Id_map.to_bybit_order_id ids (Exchange_core.Order_id.of_int (-42))
       : Order_id.t option)];
  [%expect {| () |}];
  let trade s =
    Id_map.trade_id ids (Exec_id.of_string s) |> Exchange_core.Trade_id.to_int
  in
  print_s
    [%sexp
      ([ trade "7"; trade "e0cbe81d-0f18-5866-9415-cf319b5dab3b"; trade "7" ] : int list)];
  [%expect {| (7 -4 7) |}]
;;

let decode of_yojson s = of_yojson (Yojson.Safe.from_string s)

let order ~status ?(reject = "EC_NoError") ?(cum = "0") ?(leaves = "0.01") () =
  decode
    Realtime_order.t_of_yojson
    (sprintf
       {|{"orderId":"fd4300ae-7847-404e-b947-b46980a4d140","orderLinkId":"mm-1","symbol":"BTCUSDT","side":"Buy","orderType":"Limit","price":"99000","qty":"0.01","timeInForce":"PostOnly","orderStatus":"%s","cumExecQty":"%s","cumExecValue":"0","avgPrice":"","leavesQty":"%s","reduceOnly":false,"rejectReason":"%s","positionIdx":0,"createdTime":"1700000000000","updatedTime":"1700000000001"}|}
       status
       cum
       leaves
       reject)
;;

let%expect_test "orders" =
  let ids = Id_map.create () in
  let show o =
    print_s
      [%sexp
        { update : Mm_core.Order_update.t = Venue.Convert.order_update ids o
        ; status : Exchange_core.Order_status.t = Venue.Convert.order_status ids o
        }]
  in
  print_s
    [%sexp
      (Venue.Convert.open_order ids (order ~status:"New" ()) : Exchange_core.Open_order.t)];
  [%expect
    {|
    ((symbol BTCUSDT) (side Buy) (px 99000) (size 0.01) (orig_size (0.01))
     (order_id -1) (client_order_id (mm-1)) (timestamp 1700000000000000000))
    |}];
  show (order ~status:"New" ());
  [%expect
    {|
    ((update
      ((order_id -1) (client_order_id (mm-1)) (symbol BTCUSDT) (side Buy)
       (px 99000) (status New) (filled 0) (remaining 0.01)
       (time 1700000000001000000)))
     (status (Resting (order_id -1) (client_order_id (mm-1)))))
    |}];
  (* Post-only crossing: cancelled by the venue, never rested. *)
  show (order ~status:"Cancelled" ~reject:"EC_PostOnlyWillTakeLiquidity" ~leaves:"0" ());
  [%expect
    {|
    ((update
      ((order_id -1) (client_order_id (mm-1)) (symbol BTCUSDT) (side Buy)
       (px 99000) (status Rejected) (filled 0) (remaining 0)
       (time 1700000000001000000)))
     (status (Rejected (Post_only_would_cross (best_bid ()) (best_ask ())))))
    |}];
  show (order ~status:"Cancelled" ~leaves:"0" ());
  [%expect
    {|
    ((update
      ((order_id -1) (client_order_id (mm-1)) (symbol BTCUSDT) (side Buy)
       (px 99000) (status Cancelled) (filled 0) (remaining 0)
       (time 1700000000001000000)))
     (status (Rejected (Unsupported Cancelled))))
    |}];
  show (order ~status:"PartiallyFilled" ~cum:"0.004" ~leaves:"0.006" ());
  [%expect
    {|
    ((update
      ((order_id -1) (client_order_id (mm-1)) (symbol BTCUSDT) (side Buy)
       (px 99000) (status Partially_filled) (filled 0.004) (remaining 0.006)
       (time 1700000000001000000)))
     (status (Resting (order_id -1) (client_order_id (mm-1)))))
    |}]
;;

let%expect_test "fills" =
  let ids = Id_map.create () in
  let e =
    decode
      Execution.t_of_yojson
      {|{"execId":"1","orderId":"1","orderLinkId":"mm-1","symbol":"BTCUSDT","side":"Sell","execPrice":"100000","execQty":"0.004","execValue":"400","execFee":"0.08","feeRate":"0.0002","execType":"Trade","isMaker":true,"execTime":"1700000000000","closedSize":"","seq":1,"category":"linear"}|}
  in
  print_s [%sexp (Venue.Convert.fill ids e : Mm_core.Fill.t)];
  [%expect
    {|
    ((trade_id 1) (order_id 1) (client_order_id (mm-1)) (symbol BTCUSDT)
     (side Sell) (px 100000) (size 0.004) (fee 0.08) (is_maker true)
     (time 1700000000000000000) (closed_pnl ()))
    |}];
  print_s [%sexp (Venue.Convert.is_fill { e with exec_type = Funding } : bool)];
  [%expect {| false |}]
;;

let%expect_test "order requests" =
  let btc = Symbol.of_string "BTCUSDT" in
  let show r =
    print_s
      [%sexp
        (Result.map (Venue.Convert.order_params r) ~f:(fun p ->
           Create_order.Params.yojson_of_t p |> Yojson.Safe.to_string)
         : (string, Exchange_core.Reject_reason.t) Result.t)]
  in
  show
    (Exchange_core.Order_request.limit
       ~tif:Alo
       ~client_order_id:(Exchange_core.Client_order_id.of_string "mm-b-0-1")
       btc
       Buy
       ~px:(Price.of_string "99000.5")
       ~size:(Size.of_string "0.01"));
  [%expect
    {|
    (Ok
     "{\"symbol\":\"BTCUSDT\",\"side\":\"Buy\",\"orderType\":\"Limit\",\"qty\":\"0.01\",\"price\":\"99000.5\",\"timeInForce\":\"PostOnly\",\"orderLinkId\":\"mm-b-0-1\"}")
    |}];
  show
    (Exchange_core.Order_request.market
       ~reduce_only:true
       btc
       Sell
       ~size:(Size.of_string "0.01"));
  [%expect
    {|
    (Ok
     "{\"symbol\":\"BTCUSDT\",\"side\":\"Sell\",\"orderType\":\"Market\",\"qty\":\"0.01\",\"reduceOnly\":true}")
    |}];
  show
    (Exchange_core.Order_request.limit
       ~client_order_id:(Exchange_core.Client_order_id.of_string (String.make 40 'x'))
       btc
       Buy
       ~px:(Price.of_string "1")
       ~size:(Size.of_string "1"));
  [%expect
    {|
    (Error
     (Unsupported "client order id: at most 36 characters from [A-Za-z0-9_-]"))
    |}];
  show
    { (Exchange_core.Order_request.market btc Buy ~size:Size.one) with
      order_type = Limit Gtc
    };
  [%expect {| (Error Invalid_price) |}]
;;

let%expect_test "reject reasons" =
  List.iter
    [ 110072, "duplicate"; 110007, "ab not enough"; 110017, "reduce-only"; 110094, "min" ]
    ~f:(fun (code, ret_msg) ->
      let error = Option.value_exn (Envelope.Error.of_code code) in
      print_s
        [%sexp
          (Venue.Convert.reject_reason { path = ""; ret_code = code; error; ret_msg }
           : Exchange_core.Reject_reason.t)]);
  [%expect
    {|
    Duplicate_client_order_id
    Insufficient_margin
    Reduce_only_would_increase
    (Unsupported "110094 min")
    |}]
;;

let%expect_test "account" =
  let wallet =
    decode
      Wallet_balance.t_of_yojson
      {|{"list":[{"accountType":"UNIFIED","totalEquity":"1000010","totalWalletBalance":"1000000","totalMarginBalance":"1000010","totalAvailableBalance":"999000","totalPerpUPL":"10","totalInitialMargin":"1000","totalMaintenanceMargin":"50","coin":[]}]}|}
  in
  let position side size =
    decode
      Position.t_of_yojson
      (sprintf
         {|{"positionIdx":0,"symbol":"BTCUSDT","side":"%s","size":"%s","avgPrice":"100000","positionValue":"1000","unrealisedPnl":"10","cumRealisedPnl":"-0.5","leverage":"10","liqPrice":"","markPrice":"101000","createdTime":"1700000000000","updatedTime":"1700000000000"}|}
         side
         size)
  in
  let max_leverage symbol =
    Option.some_if (Symbol.equal symbol (Symbol.of_string "BTCUSDT")) 100
  in
  print_s
    [%sexp
      (Venue.Convert.account
         ~api_key:"mm"
         ~max_leverage
         ~time:0
         wallet
         [ position "Sell" "0.01"; position "" "0" ]
       : Exchange_core.Account_view.t)];
  [%expect
    {|
    ((account mm) (balance 1000000) (equity 1000010) (total_notional 1000)
     (margin_used 1000) (maintenance_margin 50) (available 999000)
     (positions
      (((symbol BTCUSDT) (size -0.01) (entry_px 100000) (notional 1000)
        (unrealized_pnl 10) (realized_pnl -0.5) (cum_funding 0)
        (liquidation_px ()) (leverage 10) (max_leverage 100) (margin_used 100))))
     (time 0))
    |}]
;;
