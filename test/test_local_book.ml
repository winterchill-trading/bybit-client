open! Core
open Bybit_protocol
open Bybit_client

let btc = Symbol.of_string "BTCUSDT"

let push ?(symbol = btc) ~type_ ~u ~b ~a () : Ws_orderbook.t =
  let levels =
    List.map ~f:(fun (px, sz) ->
      { Book_level.price = Price.of_string px; size = Size.of_string sz })
  in
  { topic = Orderbook { depth = 50; symbol }
  ; type_
  ; ts = Timestamp_ms.of_int_ms (1_700_000_000_000 + u)
  ; data = { s = symbol; b = levels b; a = levels a; u; seq = u }
  ; cts = None
  }
;;

let show book outcome =
  print_s [%sexp (outcome : Local_book.Outcome.t)];
  match Local_book.to_l2 ~depth:3 book with
  | None -> print_endline "not synced"
  | Some l2 ->
    let side levels =
      List.map levels ~f:(fun (l : Exchange_core.L2.Level.t) ->
        sprintf "%s@%s" (Size.to_string l.sz) (Price.to_string l.px))
      |> String.concat ~sep:" "
    in
    printf
      "u=%s bids [%s] asks [%s]\n"
      (Option.value_map (Local_book.update_id book) ~default:"-" ~f:Int.to_string)
      (side l2.bids)
      (side l2.asks)
;;

let%expect_test "snapshot, deltas, stale and gap" =
  let book = Local_book.create btc in
  let apply p = show book (Local_book.apply book p) in
  apply (push ~type_:Delta ~u:4 ~b:[ "100", "1" ] ~a:[] ());
  [%expect {|
    Waiting_for_snapshot
    not synced
    |}];
  apply
    (push
       ~type_:Snapshot
       ~u:5
       ~b:[ "100", "1"; "99.5", "2"; "99", "3"; "98", "4" ]
       ~a:[ "101", "1"; "102", "2" ]
       ());
  [%expect {|
    Applied
    u=5 bids [1@100 2@99.5 3@99] asks [1@101 2@102]
    |}];
  (* Size 0 deletes, a new price inserts, an existing one is replaced. *)
  apply (push ~type_:Delta ~u:6 ~b:[ "100", "0"; "99.7", "5" ] ~a:[ "101", "0.5" ] ());
  [%expect {|
    Applied
    u=6 bids [5@99.7 2@99.5 3@99] asks [0.5@101 2@102]
    |}];
  apply (push ~type_:Delta ~u:6 ~b:[ "99.7", "9" ] ~a:[] ());
  [%expect {|
    Stale
    u=6 bids [5@99.7 2@99.5 3@99] asks [0.5@101 2@102]
    |}];
  (* u jumps from 6 to 8: the book is dropped until the next snapshot. *)
  apply (push ~type_:Delta ~u:8 ~b:[ "99.8", "1" ] ~a:[] ());
  [%expect {|
    (Gap (expected 7) (received 8))
    not synced
    |}];
  apply (push ~type_:Delta ~u:9 ~b:[ "99.8", "1" ] ~a:[] ());
  [%expect {|
    Waiting_for_snapshot
    not synced
    |}];
  apply (push ~type_:Snapshot ~u:20 ~b:[ "99", "1" ] ~a:[ "100", "1" ] ());
  [%expect {|
    Applied
    u=20 bids [1@99] asks [1@100]
    |}];
  apply (push ~type_:Delta ~u:21 ~b:[] ~a:[ "100.5", "2" ] ());
  [%expect {|
    Applied
    u=21 bids [1@99] asks [1@100 2@100.5]
    |}];
  (* A service restart sends a snapshot with u = 1. *)
  apply (push ~type_:Snapshot ~u:1 ~b:[ "98", "1" ] ~a:[ "99", "1" ] ());
  [%expect {|
    Applied
    u=1 bids [1@98] asks [1@99]
    |}];
  print_s [%sexp (Option.map (Local_book.to_l2 book) ~f:(fun l2 -> l2.time) : int option)];
  [%expect {| (1700000000001000000) |}]
;;

let%expect_test "pushes for another symbol raise" =
  let book = Local_book.create btc in
  match
    Local_book.apply
      book
      (push ~symbol:(Symbol.of_string "ETHUSDT") ~type_:Snapshot ~u:1 ~b:[] ~a:[] ())
  with
  | (_ : Local_book.Outcome.t) -> print_endline "applied"
  | exception exn ->
    print_s [%sexp (exn : exn)];
    [%expect {| ("Local_book.apply: wrong symbol" (book BTCUSDT) (push ETHUSDT)) |}]
;;

let%expect_test "apply_scan agrees with apply on every recorded orderbook frame" =
  List.iter [ "bbo"; "l2" ] ~f:(fun stream ->
    let frames = In_channel.read_lines ("fixtures/" ^ stream ^ ".jsonl") in
    let scan = Frame_scan.create () in
    let symbol = Symbol.of_string "BTCUSDT" in
    let by_decode = Local_book.create symbol
    and by_scan = Local_book.create symbol in
    let compared = ref 0 in
    List.iter frames ~f:(fun frame ->
      match Public_ws.For_testing.decode frame with
      | Ok (Orderbook push) ->
        assert (Frame_scan.scan scan frame);
        let expected = Local_book.apply by_decode push in
        let actual = Local_book.apply_scan by_scan ~frame scan in
        if not (Local_book.Outcome.equal actual expected)
        then
          raise_s
            [%message (actual : Local_book.Outcome.t) (expected : Local_book.Outcome.t)];
        [%test_result: Exchange_core.L2.t option]
          (Local_book.to_l2 by_scan)
          ~expect:(Local_book.to_l2 by_decode);
        [%test_result: (Price.t * Size.t) option]
          (Local_book.best_bid by_scan)
          ~expect:
            (Option.bind (Local_book.to_l2 by_decode) ~f:(fun l2 ->
               List.hd l2.bids |> Option.map ~f:(fun l -> l.px, l.sz)));
        incr compared
      | _ -> assert (not (Frame_scan.scan scan frame)));
    print_s [%message stream ~compared:(!compared : int)]);
  [%expect {|
    (bbo (compared 579))
    (l2 (compared 850))
    |}]
;;
