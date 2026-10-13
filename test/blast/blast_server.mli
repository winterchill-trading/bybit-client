(** A websocket server on 127.0.0.1 that writes many copies of one text frame as fast as
    the socket takes them, for measuring a client's cost per frame.

    The frame is encoded once, so the server allocates almost nothing per frame and the
    minor words counted in the same process are the client's. *)

open! Core
open Async

type t

(** [start ~frame ~per_write ()] listens on a port chosen by the OS. [blast] writes
    [per_write] copies of [frame] per socket write. [greeting] frames (default none) are
    written on every connection in the same write as the upgrade response, so they reach
    the client together with the end of the handshake. *)
val start : ?greeting:string list -> frame:string -> per_write:int -> unit -> t Deferred.t

val port : t -> int

(** Determined once the latest connection has sent its first frame (a subscription, say),
    so that a [blast] after it is not mixed with the client's handshake work. *)
val ready : t -> unit Deferred.t

(** [blast t ~n] writes [n] (rounded up to a multiple of [per_write]) frames on the latest
    connection, waiting for each write to flush, and returns the number written. *)
val blast : t -> n:int -> int Deferred.t

val close : t -> unit Deferred.t
