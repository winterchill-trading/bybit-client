(* [Market_data.Rebuild_norm] with [Raw_normalizer] over raw minute files made from the
   recorded fixtures, then the event logs read back. *)

open! Core
open Async
open Bybit_client
module Md = Market_data

let date = Date.of_string "2026-10-12"
let start = Time_ns.of_string_with_utc_offset "2026-10-12 12:00:00Z"
let streams : Md.Stream.t list = [ Trades; Bbo; L2; Funding ]

let with_temp_dir f =
  let%bind dir = Unix.mkdtemp (Filename.temp_dir_name ^/ "bybit-client-test") in
  Monitor.protect
    (fun () -> f dir)
    ~finally:(fun () ->
      Process.run_expect_no_stdout_exn ~prog:"rm" ~args:[ "-rf"; dir ] ())
;;

(* One frame every 20 ms from 12:00:00, so each stream fits in the 12-00 minute. The L2
   series records a disconnect after its first 400 frames. *)
let write_raw_minute ~data_dir (stream : Md.Stream.t) =
  let name = Md.Stream.to_string stream in
  let dir = data_dir ^/ sprintf "raw/bybit/%s/BTCUSDT/2026/10/12" name in
  let%bind () = Unix.mkdir ~p:() dir in
  let lines =
    In_channel.read_lines ("fixtures/" ^ name ^ ".jsonl")
    |> List.mapi ~f:(fun i frame ->
      let recv_ts = Time_ns.add start (Time_ns.Span.of_int_ms (20 * i)) in
      sprintf
        "%s %s"
        (Time_ns.to_string_iso8601_basic recv_ts ~zone:Time_float.Zone.utc)
        frame)
  in
  let lines =
    match stream with
    | L2 -> List.take lines 400 @ [ "" ] @ List.drop lines 400
    | Trades | Bbo | Funding | Private -> lines
  in
  Writer.save_lines (dir ^/ "12-00.ndjson") lines
;;

let%expect_test "rebuild norm from fixture minutes" =
  with_temp_dir (fun dir ->
    let data_dir = dir ^/ "data" in
    let out_dir = dir ^/ "norm" in
    let%bind () =
      Deferred.List.iter streams ~how:`Sequential ~f:(write_raw_minute ~data_dir)
    in
    let%bind stats =
      Md.Rebuild_norm.run ~normalizers:[ (module Raw_normalizer) ] ~data_dir ~out_dir date
    in
    print_s [%sexp (stats : Md.Rebuild_norm.Stats.t Or_error.t)];
    let%map () =
      Deferred.List.iter streams ~how:`Sequential ~f:(fun stream ->
        let path =
          Md.Event_log.path
            ~dir:out_dir
            (Md.Instrument.create Bybit "BTCUSDT")
            stream
            date
        in
        let%map events, tail = Md.Event_log.load_file path in
        print_s
          [%message
            ""
              ~file:(String.chop_prefix_exn path ~prefix:(dir ^ "/") : string)
              ~events:(List.length events : int)
              (tail : Md.Framed.Tail.t)])
    in
    [%expect
      {|
      (Ok
       ((files 4) (frames 1837) (disconnects 1) (events 1507) (frame_errors 0)
        (first_errors ()) (skipped_files 0) (skipped_venues ())))
      ((file norm/bybit/BTCUSDT/norm/trades/2026-10-12.bin) (events 487)
       (tail Clean))
      ((file norm/bybit/BTCUSDT/norm/bbo/2026-10-12.bin) (events 579) (tail Clean))
      ((file norm/bybit/BTCUSDT/norm/l2/2026-10-12.bin) (events 399) (tail Clean))
      ((file norm/bybit/BTCUSDT/norm/funding/2026-10-12.bin) (events 42)
       (tail Clean))
      |}])
;;
