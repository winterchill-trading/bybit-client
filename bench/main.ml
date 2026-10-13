open! Core
open Core_bench
open Bybit_client

(* Run from the repository root, or point BYBIT_FIXTURES at test/fixtures. *)
let fixtures = Option.value (Sys.getenv "BYBIT_FIXTURES") ~default:"test/fixtures"
let recv_ts = Time_ns.epoch

(* One call handles the next frame of the stream, cycling; every fixture starts with a
   snapshot, so the books stay consistent across laps. *)
let cycle items ~f =
  let items = Array.of_list items in
  let i = ref 0 in
  fun () ->
    f items.(!i);
    i := (!i + 1) % Array.length items
;;

let benches stream =
  let frames = In_channel.read_lines (fixtures ^/ stream ^ ".jsonl") in
  let messages =
    List.filter_map frames ~f:(fun frame ->
      Public_ws.For_testing.decode frame |> Result.ok)
  in
  let frame_normalizer = Live_feed.Normalizer.create () in
  let scan = Frame_scan.create () in
  let message_normalizer = Live_feed.Normalizer.create () in
  [ Bench.Test.create
      ~name:(stream ^ " decode")
      (cycle frames ~f:(fun frame ->
         ignore (Public_ws.For_testing.decode frame : _ Or_error.t)))
  ; Bench.Test.create
      ~name:(stream ^ " scan")
      (cycle frames ~f:(fun frame -> ignore (Frame_scan.scan scan frame : bool)))
  ; Bench.Test.create
      ~name:(stream ^ " normalize")
      (cycle messages ~f:(fun message ->
         ignore
           (Live_feed.Normalizer.message message_normalizer ~recv_ts message
            : Live_feed.Normalizer.Output.t)))
  ; Bench.Test.create
      ~name:(stream ^ " frame")
      (cycle frames ~f:(fun frame ->
         ignore
           (Live_feed.Normalizer.frame frame_normalizer ~recv_ts frame
            : Live_feed.Normalizer.Output.t Or_error.t)))
  ]
;;

let () =
  Command_unix.run
    (Bench.make_command (List.concat_map [ "trades"; "bbo"; "l2"; "funding" ] ~f:benches))
;;
