open! Core
open Async
open Bybit_client
module Ws_client = Venue_net.Ws_client

type result =
  { seconds : float
  ; words : float
  }

let frame =
  {|{"topic":"publicTrade.BTCUSDT","type":"snapshot","ts":1791817519381,"data":[{"T":1791817519380,"s":"BTCUSDT","S":"Sell","v":"0.001","p":"82597.20","L":"MinusTick","i":"b212143d-7faf-5703-99d8-a3f5c8c78c38","BT":false,"RPI":false,"seq":824376729135}]}|}
;;

let ws_url server =
  Uri.of_string (sprintf "ws://127.0.0.1:%d/v5/public/linear" (Blast_server.port server))
;;

let config server =
  Config.Read_only.create
    ~base_url:(Uri.of_string "http://127.0.0.1:1")
    ~ws_public_url:(ws_url server)
    ()
;;

(* [count] is advanced by the consumer; [done_] is filled by it at [target]. *)
type progress =
  { mutable count : int
  ; mutable target : int
  ; mutable done_ : unit Ivar.t
  }

let advance p k =
  p.count <- p.count + k;
  if p.count >= p.target then Ivar.fill_if_empty p.done_ ()
;;

let measure server p ~n =
  p.count <- 0;
  p.target <- n;
  p.done_ <- Ivar.create ();
  Gc.full_major ();
  let words0 = Gc.minor_words () in
  let t0 = Time_ns.now () in
  let%bind (_ : int) = Blast_server.blast server ~n in
  let%map () = Ivar.read p.done_ in
  let t1 = Time_ns.now () in
  let words1 = Gc.minor_words () in
  { seconds = Time_ns.Span.to_sec (Time_ns.diff t1 t0)
  ; words = Float.of_int (words1 - words0) /. Float.of_int n
  }
;;

let runs_of server p ~n ~runs =
  let%bind (_ : result) = measure server p ~n in
  Deferred.List.init runs ~how:`Sequential ~f:(fun _ -> measure server p ~n)
;;

let progress () = { count = 0; target = Int.max_value; done_ = Ivar.create () }

let floor server ~n ~runs =
  let p = progress () in
  let%bind client =
    Ws_client.connect
      ~on_message:(fun (_ : string) -> advance p 1)
      ~url:(ws_url server)
      ()
    >>| ok_exn
  in
  let%bind () = Ws_client.send client "hello" in
  let%bind () = Blast_server.ready server in
  let%bind results = runs_of server p ~n ~runs in
  let%map () = Ws_client.close client in
  results
;;

let batch_counter p batch =
  advance p (Queue.length batch);
  return ()
;;

let live_feed server ~n ~runs =
  let p = progress () in
  let%bind live =
    Live_feed.connect (config server) ~symbols:[ "BTCUSDT" ] ~streams:[ Trades ]
  in
  let (module Feed : Market_data.Feed.S) = Live_feed.feed live in
  don't_wait_for (Pipe.iter' Feed.trades ~f:(batch_counter p));
  let%bind () = Blast_server.ready server in
  let%bind results = runs_of server p ~n ~runs in
  let%map () = Feed.close () in
  results
;;

let public_ws server ~n ~runs =
  let p = progress () in
  let%bind ws = Public_ws.connect (config server) >>| ok_exn in
  don't_wait_for (Pipe.iter' (Public_ws.messages ws) ~f:(batch_counter p));
  let%bind () =
    Public_ws.subscribe
      ws
      (Bybit_protocol.Topic.Public_trade (Bybit_protocol.Symbol.of_string "BTCUSDT"))
  in
  let%bind () = Blast_server.ready server in
  let%bind results = runs_of server p ~n ~runs in
  let%map () = Public_ws.close ws in
  results
;;
