open! Core
open Async
open Bybit_client

let trade id =
  sprintf
    {|{"topic":"publicTrade.BTCUSDT","type":"snapshot","ts":1672304486868,"data":[{"T":1672304486865,"s":"BTCUSDT","S":"Buy","v":"0.001","p":"16578.50","L":"PlusTick","i":"%d","BT":false}]}|}
    id
;;

let print_stats feed =
  List.iter (Live_feed.stats feed) ~f:(fun (stream, stats) ->
    print_s [%message (Market_data.Stream.to_string stream) (stats : Live_feed.Stats.t)])
;;

let%expect_test "a malformed frame counts as a parse error and is skipped" =
  Log.Global.set_output [];
  let%bind server = Loopback.start () in
  let%bind live =
    Live_feed.connect (Loopback.config server) ~symbols:[ "BTCUSDT" ] ~streams:[ Trades ]
  in
  let (module Feed) = Live_feed.feed live in
  let%bind (_ : bool) =
    Loopback.wait_until (fun () -> not (List.is_empty (Loopback.received server)))
  in
  print_s [%sexp (Loopback.received server : string list)];
  Loopback.push server (trade 1);
  Loopback.push server {|{"topic":"publicTrade.BTCUSDT","type":"snapshot","data":[{|};
  Loopback.push server "not json at all";
  Loopback.push server (trade 2);
  let%bind trades = Pipe.read_exactly Feed.trades ~num_values:2 in
  (match trades with
   | `Exactly trades ->
     Queue.iter trades ~f:(fun (trade : Market_data.Trade.t) ->
       print_endline trade.trade_id)
   | `Eof | `Fewer _ -> print_endline "missing trades");
  print_stats live;
  let%bind () = Feed.close () in
  let%bind () = Loopback.close server in
  [%expect
    {|
    ("{\"op\":\"subscribe\",\"args\":[\"publicTrade.BTCUSDT\"]}")
    1
    2
    (trades (stats ((frames 4) (parse_errors 2) (reconnects 0))))
    |}];
  return ()
;;

let%expect_test "reconnect on a synthetic clock: resubscribes, counts, stamps recv_ts" =
  Log.Global.set_output [];
  let%bind server = Loopback.start () in
  let clock = Time_source.create ~now:Time_ns.epoch () in
  let%bind live =
    Live_feed.connect
      ~time_source:(Time_source.read_only clock)
      (Loopback.config server)
      ~symbols:[ "BTCUSDT" ]
      ~streams:[ Trades ]
  in
  let (module Feed) = Live_feed.feed live in
  let subscribes () =
    List.count (Loopback.received server) ~f:(String.is_substring ~substring:"subscribe")
  in
  let%bind (_ : bool) = Loopback.wait_until (fun () -> subscribes () = 1) in
  let%bind () = Loopback.drop server in
  let%bind (_ : bool) =
    Loopback.wait_until (fun () ->
      match Time_source.next_alarm_fires_at clock with
      | Some at -> Time_ns.Span.(Time_ns.diff at (Time_source.now clock) < of_int_sec 1)
      | None -> false)
  in
  (* Nothing reconnects until the synthetic clock passes the backoff. *)
  let%bind () = Clock_ns.after (Time_ns.Span.of_int_ms 50) in
  print_s [%message "before advancing" ~connections:(Loopback.connections server : int)];
  let%bind () = Time_source.advance_by_alarms_by clock (Time_ns.Span.of_int_sec 1) in
  let%bind (_ : bool) = Loopback.wait_until (fun () -> subscribes () = 2) in
  Loopback.push server (trade 3);
  let%bind trade = Pipe.read Feed.trades in
  (match trade with
   | `Ok trade ->
     print_s
       [%message
         "after advancing"
           ~connections:(Loopback.connections server : int)
           ~recv_ts:(Time_ns.to_int63_ns_since_epoch trade.recv_ts : Int63.t)]
   | `Eof -> print_endline "no trade");
  print_stats live;
  let%bind () = Feed.close () in
  let%bind () = Loopback.close server in
  [%expect
    {|
    ("before advancing" (connections 1))
    ("after advancing" (connections 2) (recv_ts 1000000000))
    (trades (stats ((frames 1) (parse_errors 0) (reconnects 1))))
    |}];
  return ()
;;
