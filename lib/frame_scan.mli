(** A [@zero_alloc] scanner for the hot public frames: [publicTrade.<symbol>] and
    [orderbook.<depth>.<symbol>] (both BBO and L2, snapshots and deltas).

    {!scan} reads one frame into a reused record: prices and sizes as {!Fixed_decimal}
    units, timestamps as integer milliseconds, strings (topic, symbols, trade ids) as
    positions into the frame, so nothing is allocated. It accepts a subset of what the
    Yojson decoder accepts and returns [false] for anything else (another topic, an
    acknowledgement, escaped strings, string timestamps, exponents, negative or
    out-of-range decimals, more levels or trades than the capacity, a missing field); the
    caller then decodes the frame with Yojson. Values of fields the scanner does not use
    are skipped without being validated. *)

open! Core

module Kind : sig
  type t =
    | Trades (** [data] is an array of trades *)
    | Book (** [data] is an orderbook object *)
  [@@deriving sexp_of, equal]
end

type t

(** [capacity] (default 1024) bounds the levels per side and the trades per frame. *)
val create : ?capacity:int -> unit -> t

(** [true] when [frame] was read completely; the accessors below then describe it until
    the next call. *)
val scan : t -> string -> bool
[@@zero_alloc]

val kind : t -> Kind.t

(** Position and length of the [topic] string in the frame (without quotes). *)
val topic_pos : t -> int

val topic_len : t -> int

(** [type] is ["snapshot"] (else ["delta"]). *)
val snapshot : t -> bool

(** [ts], in milliseconds. *)
val ts : t -> int

(** {2 Book} *)

(** [data.s] *)
val symbol_pos : t -> int

val symbol_len : t -> int

(** [data.u] *)
val update_id : t -> int

val bids : t -> int
val asks : t -> int

(** Level [i] of the bids or asks, in frame order, in {!Fixed_decimal} units. *)
val bid_price : t -> int -> int

val bid_size : t -> int -> int
val ask_price : t -> int -> int
val ask_size : t -> int -> int

(** {2 Trades} *)

val trades : t -> int

(** [T], milliseconds. *)
val trade_time : t -> int -> int

val trade_price : t -> int -> int
val trade_size : t -> int -> int

(** [S = "Buy"]. *)
val trade_buy : t -> int -> bool

val trade_symbol_pos : t -> int -> int
val trade_symbol_len : t -> int -> int

(** [i] *)
val trade_id_pos : t -> int -> int

val trade_id_len : t -> int -> int

(** [equal_sub frame ~pos ~len s]: the [len] bytes of [frame] at [pos] are [s]. *)
val equal_sub : string -> pos:int -> len:int -> string -> bool
[@@zero_alloc]
