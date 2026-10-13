(* Frames per second and minor words per frame of [Live_feed] and [Public_ws] against a
   websocket server on 127.0.0.1 in the same process, next to a bare [Ws_client] that only
   counts frames (the transport floor). The server writes one pre-encoded publicTrade
   frame, either 1,000 per write (burst) or one per write. *)

open! Core
open Async
open Bybit_client_blast

let runs = 5

let report name ~n (results : Feed_cost.result list) =
  let best =
    List.min_elt results ~compare:(fun a b -> Float.compare a.seconds b.seconds)
    |> Option.value_exn
  in
  let words = List.map results ~f:(fun r -> r.words) in
  printf
    "  %-10s %9.0f frames/s  %7.1f ns/frame  %6.1f words/frame (min %.1f max %.1f)\n%!"
    name
    (Float.of_int n /. best.seconds)
    (best.seconds *. 1e9 /. Float.of_int n)
    (List.sum (module Float) words ~f:Fn.id /. Float.of_int (List.length words))
    (Option.value_exn (List.min_elt words ~compare:Float.compare))
    (Option.value_exn (List.max_elt words ~compare:Float.compare))
;;

let main () =
  Log.Global.set_output [];
  Deferred.List.iter
    ~how:`Sequential
    [ "burst", 200_000, 1_000; "one per write", 20_000, 1 ]
    ~f:(fun (scenario, n, per_write) ->
      printf
        "%s: %d frames of %d bytes per run, %d per server write, best of %d runs\n%!"
        scenario
        n
        (String.length Feed_cost.frame)
        per_write
        runs;
      let%bind server = Blast_server.start ~frame:Feed_cost.frame ~per_write () in
      let%bind floor = Feed_cost.floor server ~n ~runs in
      report "ws floor" ~n floor;
      let%bind feed = Feed_cost.live_feed server ~n ~runs in
      report "live feed" ~n feed;
      let%bind public_ws = Feed_cost.public_ws server ~n ~runs in
      report "public ws" ~n public_ws;
      Blast_server.close server)
;;

let () =
  Command_unix.run
    (Command.async
       ~summary:"Live_feed and Public_ws frames/s against a local server"
       (Command.Param.return main))
;;
