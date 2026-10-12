open! Core
open Bybit_protocol
open Bybit_client

let recv_ts = Time_ns.of_string_with_utc_offset "2026-10-12 12:00:00.000000000Z"
let streams = [ "trades"; "bbo"; "l2"; "funding" ]
let frames stream = In_channel.read_lines ("fixtures/" ^ stream ^ ".jsonl")

let message_kind : Ws_message.t -> string = function
  | Public_trade _ -> "trade"
  | Orderbook _ -> "orderbook"
  | Ticker _ -> "ticker"
  | Subscribe_ack _ -> "ack"
  | Auth_ack _ | Op_response _ -> "op"
  | Pong _ -> "pong"
  | Order _ | Execution _ | Position _ | Wallet _ -> "private"
  | Unknown _ -> "unknown"
;;

let event_kind : Market_data.Event.t -> string = function
  | Trade _ -> "Trade"
  | Bbo _ -> "Bbo"
  | L2 { kind = Snapshot; _ } -> "L2 snapshot"
  | L2 { kind = Delta; _ } -> "L2 delta"
  | Funding _ -> "Funding"
;;

let count table key = Hashtbl.update table key ~f:(fun n -> 1 + Option.value n ~default:0)

let%expect_test "every recorded frame decodes" =
  List.iter streams ~f:(fun stream ->
    let kinds = String.Table.create () in
    List.iter (frames stream) ~f:(fun frame ->
      match Public_ws.For_testing.decode frame with
      | Ok message -> count kinds (message_kind message)
      | Error _ -> count kinds "ERROR");
    print_s
      [%sexp
        (stream : string)
        , (Hashtbl.to_alist kinds |> List.sort ~compare:[%compare: string * int]
           : (string * int) list)]);
  [%expect
    {|
    (trades ((ack 1) (trade 224)))
    (bbo ((ack 1) (orderbook 579)))
    (l2 ((ack 1) (orderbook 850)))
    (funding ((ack 1) (ticker 180)))
    |}]
;;

let%expect_test "per-stream normalizer counts" =
  List.iter streams ~f:(fun stream ->
    let normalizer = Live_feed.Normalizer.create () in
    let events = String.Table.create () in
    let errors = ref 0
    and resubscribes = ref 0 in
    List.iter (frames stream) ~f:(fun frame ->
      match Live_feed.Normalizer.frame normalizer ~recv_ts frame with
      | Error _ -> incr errors
      | Ok { events = es; resubscribe } ->
        resubscribes := !resubscribes + List.length resubscribe;
        List.iter es ~f:(fun e -> count events (event_kind e)));
    print_s
      [%message
        stream
          ~frames:(List.length (frames stream) : int)
          ~events:
            (Hashtbl.to_alist events |> List.sort ~compare:[%compare: string * int]
             : (string * int) list)
          ~errors:(!errors : int)
          ~resubscribes:(!resubscribes : int)]);
  [%expect
    {|
    (trades (frames 225) (events ((Trade 487))) (errors 0) (resubscribes 0))
    (bbo (frames 580) (events ((Bbo 579))) (errors 0) (resubscribes 0))
    (l2 (frames 851) (events (("L2 delta" 849) ("L2 snapshot" 1))) (errors 0)
     (resubscribes 0))
    (funding (frames 181) (events ((Funding 42))) (errors 0) (resubscribes 0))
    |}]
;;

(* Minor-heap words allocated per frame: decoding the JSON into a [Ws_message.t], then
   normalizing it (book and ticker state included). *)
let%expect_test "allocation per frame" =
  List.iter streams ~f:(fun stream ->
    let frames = frames stream in
    let n = List.length frames in
    let words f =
      let before = Gc.minor_words () in
      let result = f () in
      (Gc.minor_words () - before) / n, result
    in
    let decode_words, messages =
      words (fun () ->
        List.filter_map frames ~f:(fun frame ->
          Public_ws.For_testing.decode frame |> Result.ok))
    in
    let normalizer = Live_feed.Normalizer.create () in
    let normalize_words, () =
      words (fun () ->
        List.iter messages ~f:(fun message ->
          ignore
            (Live_feed.Normalizer.message normalizer ~recv_ts message
             : Live_feed.Normalizer.Output.t)))
    in
    print_s
      [%message
        stream
          ~bytes_per_frame:(List.sum (module Int) frames ~f:String.length / n : int)
          (decode_words : int)
          (normalize_words : int)]);
  [%expect
    {|
    (trades (bytes_per_frame 452) (decode_words 817) (normalize_words 42))
    (bbo (bytes_per_frame 195) (decode_words 505) (normalize_words 118))
    (l2 (bytes_per_frame 366) (decode_words 1111) (normalize_words 489))
    (funding (bytes_per_frame 236) (decode_words 502) (normalize_words 30))
    |}]
;;
