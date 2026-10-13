(** Bybit's public linear stream ([/v5/public/linear]): orderbooks, public trades and
    tickers.

    - [{"op":"ping"}] is sent every [ping_interval] (default 20s, as Bybit recommends); if
      nothing arrives during two consecutive intervals the socket is replaced.
    - On close the client reconnects with exponential backoff, resends every subscription
      (the server answers with fresh snapshots) and then calls [on_reconnect].
    - [messages] carries every decoded message, including acks and pongs; undecodable
      frames are logged at debug level and dropped. Buffered without pushback.
    - [on_raw] is called with every text frame exactly as received, before decoding.
    - [intercept] is called with every text frame after [on_raw]; returning [true] marks
      the frame handled, so it is not decoded, passed to [on_frame] or written to
      [messages] ({!Live_feed} uses this for the frames its scanner reads).
    - [on_frame] is called with every text frame and its decoding, before the message is
      written to [messages]; a consumer that only needs a callback avoids a second parse.
    - [time_source] (default the wall clock) drives the keepalive, the watchdog and the
      reconnect backoff, so tests can step them with a synthetic clock. *)

open! Core
open Async
open Bybit_protocol

type t

val connect
  :  ?ping_interval:Time_ns.Span.t
  -> ?initial_backoff:Time_ns.Span.t
  -> ?max_backoff:Time_ns.Span.t
  -> ?on_reconnect:(unit -> unit)
  -> ?on_raw:(string -> unit)
  -> ?intercept:(string -> bool)
  -> ?on_frame:(string -> Ws_message.t Or_error.t -> unit)
  -> ?time_source:Time_source.t
  -> Config.Read_only.t
  -> t Or_error.t Deferred.t

val messages : t -> Ws_message.t Pipe.Reader.t

(** Subscribe now and after every reconnection. Idempotent. *)
val subscribe : t -> Topic.t -> unit Deferred.t

val unsubscribe : t -> Topic.t -> unit Deferred.t

(** Unsubscribe and subscribe again: the server then sends a new snapshot. *)
val resubscribe : t -> Topic.t -> unit Deferred.t

val subscriptions : t -> Topic.t list
val send : t -> Ws_request.t -> unit Deferred.t
val is_connected : t -> bool

(** Successful reconnections so far; the first connection does not count. *)
val reconnects : t -> int

val close : t -> unit Deferred.t

module For_testing : sig
  val decode : string -> Ws_message.t Or_error.t
  val encode : Ws_request.t -> string
end
