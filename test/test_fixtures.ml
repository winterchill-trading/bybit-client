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

let%expect_test "the scanner and the Yojson path give identical outputs on every frame" =
  List.iter streams ~f:(fun stream ->
    let by_decode = Live_feed.Normalizer.create ()
    and by_frame = Live_feed.Normalizer.create ()
    and by_scan = Live_feed.Normalizer.create () in
    let scanned = ref 0 in
    List.iter (frames stream) ~f:(fun frame ->
      let expected =
        Or_error.bind (Public_ws.For_testing.decode frame) ~f:(fun message ->
          Or_error.try_with (fun () ->
            Live_feed.Normalizer.message by_decode ~recv_ts message))
      in
      let actual = Live_feed.Normalizer.frame by_frame ~recv_ts frame in
      let scan = Live_feed.Normalizer.scan by_scan ~recv_ts frame in
      (match scan with
       | Some _ -> incr scanned
       | None ->
         (* keep [by_scan]'s state in step through the Yojson path *)
         ignore
           (Or_error.bind (Public_ws.For_testing.decode frame) ~f:(fun message ->
              Or_error.try_with (fun () ->
                Live_feed.Normalizer.message by_scan ~recv_ts message))
            : Live_feed.Normalizer.Output.t Or_error.t));
      let sexp = [%sexp_of: Live_feed.Normalizer.Output.t Or_error.t] in
      if not (Sexp.equal (sexp expected) (sexp actual))
      then
        print_s
          [%message
            "frame differs" frame (expected |> sexp : Sexp.t) (actual |> sexp : Sexp.t)];
      Option.iter scan ~f:(fun scan ->
        if not (Sexp.equal (sexp expected) (sexp (Ok scan)))
        then print_s [%message "scan differs" frame]));
    print_s
      [%message
        stream ~frames:(List.length (frames stream) : int) ~scanned:(!scanned : int)]);
  [%expect
    {|
    (trades (frames 225) (scanned 224))
    (bbo (frames 580) (scanned 579))
    (l2 (frames 851) (scanned 850))
    (funding (frames 181) (scanned 0))
    |}]
;;

(* Minor-heap words allocated per frame: decoding the JSON into a [Ws_message.t], then
   normalizing it (book and ticker state included), and [Normalizer.frame], which scans
   trade and orderbook frames without a JSON tree. Counts differ by a few words between
   macOS and Linux, so each is printed as its pinned (macOS) value when within 1% or 8
   words of it, and as the raw count otherwise. *)
let pinned =
  [ "trades", (756, 42, 51)
  ; "bbo", (451, 62, 74)
  ; "l2", (831, 459, 532)
  ; "funding", (435, 30, 470)
  ]
;;

(* The pins are the macOS arm64 counts; amd64 CI can differ by a few words, which
   [near] allows for (8 words or 1%, whichever is larger). *)
let near ~expected actual =
  if abs (actual - expected) <= Int.max 8 (expected / 100) then expected else actual
;;

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
    let frame_normalizer = Live_feed.Normalizer.create () in
    let frame_words, () =
      words (fun () ->
        List.iter frames ~f:(fun frame ->
          ignore
            (Live_feed.Normalizer.frame frame_normalizer ~recv_ts frame
             : Live_feed.Normalizer.Output.t Or_error.t)))
    in
    let expected_decode, expected_normalize, expected_frame =
      List.Assoc.find_exn pinned ~equal:String.equal stream
    in
    print_s
      [%message
        stream
          ~bytes_per_frame:(List.sum (module Int) frames ~f:String.length / n : int)
          ~decode_words:(near ~expected:expected_decode decode_words : int)
          ~normalize_words:(near ~expected:expected_normalize normalize_words : int)
          ~frame_words:(near ~expected:expected_frame frame_words : int)]);
  [%expect
    {|
    (trades (bytes_per_frame 452) (decode_words 756) (normalize_words 42)
     (frame_words 51))
    (bbo (bytes_per_frame 195) (decode_words 451) (normalize_words 62)
     (frame_words 74))
    (l2 (bytes_per_frame 366) (decode_words 831) (normalize_words 459)
     (frame_words 532))
    (funding (bytes_per_frame 236) (decode_words 435) (normalize_words 30)
     (frame_words 470))
    |}]
;;
