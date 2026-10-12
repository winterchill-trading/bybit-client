open! Core
open Bybit_protocol

type t =
  { mutable next : int (** next negative id, as a positive count *)
  ; to_int : int String.Table.t
  ; of_int : string Int.Table.t
  }

let create () =
  { next = 1; to_int = String.Table.create (); of_int = Int.Table.create () }
;;

let numeric s =
  if (not (String.is_empty s))
     && String.length s <= 19
     && String.for_all s ~f:Char.is_digit
  then Option.try_with (fun () -> Int64.to_int_exn (Int64.of_string s))
  else None
;;

let to_int t s =
  match numeric s with
  | Some n -> n
  | None ->
    Hashtbl.find_or_add t.to_int s ~default:(fun () ->
      let id = -t.next in
      t.next <- t.next + 1;
      Hashtbl.set t.of_int ~key:id ~data:s;
      id)
;;

let order_id t id = Exchange_core.Order_id.of_int (to_int t (Order_id.to_string id))

let to_bybit_order_id t id =
  let n = Exchange_core.Order_id.to_int_exn id in
  if n >= 0
  then Some (Order_id.of_string (Int.to_string n))
  else Hashtbl.find t.of_int n |> Option.map ~f:Order_id.of_string
;;

let trade_id t id = Exchange_core.Trade_id.of_int (to_int t (Exec_id.to_string id))
