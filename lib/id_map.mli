(** Bybit's string ids mapped to the integer ids of [exchange-core] ([Order_id],
    [Trade_id]).

    Bybit sends [orderId] and [execId] as strings: decimal numbers on some products (and
    in the simulator, which uses the engine's ids) and UUIDs on others. The mapping is:

    - a decimal string that fits a non-negative [int64] maps to that number, so ids read
      the same on both sides and need no table;
    - any other string gets the next negative number ([-1], [-2], ...), remembered in a
      table for the lifetime of the map, so the same string always maps to the same id and
      the two ranges never collide.

    Order ids map back ({!to_bybit_order_id}); negative ids not handed out by this map
    have no Bybit counterpart. One map per connection: negative ids are not stable across
    processes. *)

open! Core
open Bybit_protocol

type t

val create : unit -> t
val order_id : t -> Order_id.t -> Exchange_core.Order_id.t

(** [None] for a negative id this map never handed out. *)
val to_bybit_order_id : t -> Exchange_core.Order_id.t -> Order_id.t option

val trade_id : t -> Exec_id.t -> Exchange_core.Trade_id.t
