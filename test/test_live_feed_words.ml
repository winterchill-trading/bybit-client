(* Minor words per frame that [Live_feed] and [Public_ws] add on top of the websocket
   transport: frames read through each, minus the same frames read by a bare [Ws_client]
   that only counts them. Both sides pay the socket reads and async_websocket's framing,
   which differ a little between macOS arm64 and Linux amd64; the difference is the
   client's own work (the frame hand-off, decoding and the output pipe). *)

open! Core
open Async
open Bybit_client_blast

let n = 20_000

let mean results =
  List.sum (module Float) results ~f:(fun (r : Feed_cost.result) -> r.words)
  /. Float.of_int (List.length results)
;;

let%expect_test "words per frame added by the live feed and the public websocket" =
  Log.Global.set_output [];
  let%bind server = Blast_server.start ~frame:Feed_cost.frame ~per_write:1_000 () in
  let%bind floor = Feed_cost.floor server ~n ~runs:3 in
  let%bind feed = Feed_cost.live_feed server ~n ~runs:3 in
  let%bind public_ws = Feed_cost.public_ws server ~n ~runs:3 in
  let over_floor results = Float.iround_nearest_exn (mean results -. mean floor) in
  (* [Public_ws] decodes with Yojson, which allocates a few words less on Linux amd64 than
     on macOS arm64: 466 against 470, as in test_fixtures.ml. Within 8 words of the arm64
     pin it prints the pin. The live feed's scanned path is the same on both. *)
  let near ~expected actual = if abs (actual - expected) <= 8 then expected else actual in
  print_s
    [%message
      "words per frame over the floor"
        ~live_feed:(over_floor feed : int)
        ~public_ws:(near ~expected:470 (over_floor public_ws) : int)];
  (* live_feed was 63 and public_ws 483 while [Ws_stream] read [Ws_client.messages] one
     frame at a time; [on_message] drops the pipe hop's 13 words. *)
  [%expect {| ("words per frame over the floor" (live_feed 50) (public_ws 470)) |}];
  Blast_server.close server
;;
