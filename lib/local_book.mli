(** A local copy of one symbol's orderbook built from [orderbook.<depth>.<symbol>] pushes.

    A snapshot replaces the book (also when [u = 1], Bybit's service restart signal).
    Deltas must arrive with consecutive update ids ([u = previous u + 1]); a level with
    size 0 is removed, any other size replaces the level. A delta that skips an id is a
    gap: the book is dropped and further deltas are ignored until the next snapshot, which
    the caller obtains by resubscribing. *)

open! Core
open Bybit_protocol

type t

module Outcome : sig
  type t =
    | Applied (** the book changed and is consistent *)
    | Stale (** a delta with [u] at or below the current one; ignored *)
    | Waiting_for_snapshot
    (** a delta before the first snapshot or after a gap; ignored *)
    | Gap of
        { expected : int
        ; received : int
        } (** the book was dropped; resubscribe to get a snapshot *)
  [@@deriving sexp_of, equal]
end

val create : Symbol.t -> t
val symbol : t -> Symbol.t

(** [Applied] snapshot or delta. Pushes for another symbol raise. *)
val apply : t -> Ws_orderbook.t -> Outcome.t

(** [true] once a snapshot has been applied and no gap has been seen since. *)
val is_synced : t -> bool

(** Last applied update id. *)
val update_id : t -> int option

(** The book, best price first, at most [depth] levels per side (default all), [time] the
    push timestamp in nanoseconds. Order counts are not sent by Bybit; [n] is 0. [None]
    while not synced. *)
val to_l2 : ?depth:int -> t -> Exchange_core.L2.t option
