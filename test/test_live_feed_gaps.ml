open! Core
open Async
open Bybit_client

let print_gap (gap : Market_data.Gap.t) =
  print_s
    [%message
      "gap"
        ~recv_ts:(Time_ns.to_int63_ns_since_epoch gap.recv_ts : Int63.t)
        ~venue:(gap.venue : Market_data.Venue.t)
        ~instrument:(gap.instrument : Market_data.Instrument.t option)
        ~stream:(gap.stream : Market_data.Stream.t option)
        ~reason:(gap.reason : Market_data.Gap.Reason.t)]
;;

(* Gaps are written before the events that follow them, so they are already there. *)
let print_gaps gaps =
  match Pipe.read_now' gaps with
  | `Ok gaps -> Queue.iter gaps ~f:print_gap
  | `Eof | `Nothing_available -> print_endline "no gaps"
;;

let book ~type_ ~u levels =
  sprintf
    {|{"topic":"orderbook.50.BTCUSDT","type":"%s","ts":1672304484978,"data":{"s":"BTCUSDT","b":[%s],"a":[["16612.00","1"]],"u":%d,"seq":%d},"cts":1672304484976}|}
    type_
    levels
    u
    u
;;

let%expect_test "a reconnect on the synthetic clock reports one Resync gap" =
  Log.Global.set_output [];
  let%bind server = Loopback.start () in
  let clock = Time_source.create ~now:Time_ns.epoch () in
  let%bind live =
    Live_feed.connect
      ~time_source:(Time_source.read_only clock)
      (Loopback.config server)
      ~symbols:[ "BTCUSDT" ]
      ~streams:[ L2 ]
  in
  let (module Feed) = Live_feed.feed_with_gaps live in
  let subscribes () =
    List.count (Loopback.received server) ~f:(String.is_substring ~substring:"subscribe")
  in
  let%bind (_ : bool) = Loopback.wait_until (fun () -> subscribes () = 1) in
  Loopback.push server (book ~type_:"snapshot" ~u:1 {|["16493.00","1"]|});
  let%bind (_ : [ `Ok of Market_data.L2_update.t | `Eof ]) = Pipe.read Feed.l2 in
  print_s [%message "before the drop" ~gaps:(Pipe.length Feed.gaps : int)];
  let%bind () = Loopback.drop server in
  (* Wait for the reconnect backoff (under a second) rather than the keepalive alarm. *)
  let%bind (_ : bool) =
    Loopback.wait_until (fun () ->
      match Time_source.next_alarm_fires_at clock with
      | Some at -> Time_ns.Span.(Time_ns.diff at (Time_source.now clock) < of_int_sec 1)
      | None -> false)
  in
  (* The first reconnect waits 500 ms with 20% jitter. *)
  (match Time_source.next_alarm_fires_at clock with
   | Some at ->
     let backoff = Time_ns.diff at (Time_source.now clock) in
     print_s
       [%message
         ""
           ~backoff_between_400_and_600_ms:
             (Time_ns.Span.(backoff >= of_int_ms 400 && backoff <= of_int_ms 600) : bool)]
   | None -> print_endline "no backoff");
  let%bind () = Time_source.advance_by_alarms_by clock (Time_ns.Span.of_int_sec 1) in
  let%bind (_ : bool) = Loopback.wait_until (fun () -> subscribes () = 2) in
  Loopback.push server (book ~type_:"snapshot" ~u:7 {|["16494.00","2"]|});
  let%bind (_ : [ `Ok of Market_data.L2_update.t | `Eof ]) = Pipe.read Feed.l2 in
  print_gaps Feed.gaps;
  let%bind () = Feed.close () in
  let%bind () = Loopback.close server in
  [%expect
    {|
    ("before the drop" (gaps 0))
    (backoff_between_400_and_600_ms true)
    (gap (recv_ts 1000000000) (venue Bybit) (instrument ()) (stream (L2))
     (reason Resync))
    |}];
  return ()
;;

let%expect_test "a sequence gap reports a Resync gap for its instrument" =
  Log.Global.set_output [];
  let%bind server = Loopback.start () in
  let clock = Time_source.create ~now:Time_ns.epoch () in
  let%bind live =
    Live_feed.connect
      ~time_source:(Time_source.read_only clock)
      (Loopback.config server)
      ~symbols:[ "BTCUSDT" ]
      ~streams:[ L2 ]
  in
  let (module Feed) = Live_feed.feed_with_gaps live in
  let subscribes () =
    List.count (Loopback.received server) ~f:(String.is_substring ~substring:"subscribe")
  in
  let%bind (_ : bool) = Loopback.wait_until (fun () -> subscribes () = 1) in
  Loopback.push server (book ~type_:"snapshot" ~u:1 {|["16493.00","1"]|});
  (* u skips 2: the topic is resubscribed *)
  Loopback.push server (book ~type_:"delta" ~u:3 {|["16493.00","2"]|});
  let%bind (_ : bool) =
    Loopback.wait_until (fun () ->
      List.count
        (Loopback.received server)
        ~f:(String.is_substring ~substring:"unsubscribe")
      = 1)
  in
  print_gaps Feed.gaps;
  print_s [%message "" ~l2_events:(Pipe.length Feed.l2 : int)];
  let%bind () = Feed.close () in
  let%bind () = Loopback.close server in
  [%expect
    {|
    (gap (recv_ts 0) (venue Bybit)
     (instrument (((venue Bybit) (symbol BTCUSDT)))) (stream (L2))
     (reason Resync))
    (l2_events 1)
    |}];
  return ()
;;
