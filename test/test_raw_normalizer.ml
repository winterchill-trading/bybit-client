(* The recorded fixtures through [Raw_normalizer], the [Market_data.Normalizer.S] adapter
   that [rebuild-norm] uses. *)

open! Core
open Bybit_client

let recv_ts = Time_ns.of_string_with_utc_offset "2026-10-12 12:00:00.000000000Z"
let frames stream = In_channel.read_lines ("fixtures/" ^ stream ^ ".jsonl")
let normalizer : Market_data.Normalizer.t = (module Raw_normalizer)

let event_kind : Market_data.Event.t -> string = function
  | Trade _ -> "Trade"
  | Bbo _ -> "Bbo"
  | L2 { kind = Snapshot; _ } -> "L2 snapshot"
  | L2 { kind = Delta; _ } -> "L2 delta"
  | Funding _ -> "Funding"
;;

let run (type a) (module N : Market_data.Normalizer.S with type t = a) (t : a) frames =
  let kinds = String.Table.create () in
  let errors = ref 0 in
  List.iter frames ~f:(fun frame ->
    match N.frame t ~recv_ts frame with
    | Error _ -> incr errors
    | Ok events ->
      List.iter events ~f:(fun e ->
        Hashtbl.update kinds (event_kind e) ~f:(fun n -> 1 + Option.value n ~default:0)));
  [%message
    ""
      ~events:
        (Hashtbl.to_alist kinds |> List.sort ~compare:[%compare: string * int]
         : (string * int) list)
      ~errors:(!errors : int)]
;;

let%expect_test "every fixture stream through the adapter" =
  let (module N) = normalizer in
  print_s [%sexp (Market_data.Normalizer.venue normalizer : Market_data.Venue.t)];
  List.iter [ "trades"; "bbo"; "l2"; "funding" ] ~f:(fun stream ->
    print_s
      [%sexp (stream : string), (run (module N) (N.create ()) (frames stream) : Sexp.t)]);
  [%expect
    {|
    Bybit
    (trades ((events ((Trade 487))) (errors 0)))
    (bbo ((events ((Bbo 579))) (errors 0)))
    (l2 ((events (("L2 delta" 849) ("L2 snapshot" 1))) (errors 0)))
    (funding ((events ((Funding 42))) (errors 0)))
    |}]
;;

let%expect_test "disconnect drops books until the next snapshot" =
  let (module N) = normalizer in
  let t = N.create () in
  let l2 = frames "l2" in
  let first = List.take l2 100
  and rest = List.drop l2 100 in
  print_s (run (module N) t first);
  N.disconnect t;
  print_s (run (module N) t rest);
  (* A snapshot (the recording's first frame) starts the book again. *)
  print_s (run (module N) t (List.take l2 2));
  [%expect
    {|
    ((events (("L2 delta" 98) ("L2 snapshot" 1))) (errors 0))
    ((events ()) (errors 0))
    ((events (("L2 delta" 1) ("L2 snapshot" 1))) (errors 0))
    |}]
;;
