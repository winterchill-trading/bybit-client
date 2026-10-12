(** A Bybit websocket stream: [Venue_net.Ws_client] with the [{"op":"ping"}] keepalive, an
    optional authentication step and the set of subscribed topics, replayed on every
    (re)connection. Shared by {!Public_ws} and {!Private_ws}. *)

open! Core
open Async
open Bybit_protocol

type t

(** [authenticate], when given, produces the [auth] request sent first on every
    connection; subscriptions are replayed once the [Auth_ack] arrives (or after
    [auth_timeout], logging an error). A failed auth is logged and the subscriptions are
    still sent (the server will refuse them).

    [on_raw] sees every text frame, unparsed, before it is decoded; [on_frame] sees it
    with its decoding (each frame is decoded once). [time_source] (default
    the wall clock) drives the keepalive, watchdog, reconnect backoff and auth timeout. *)
val connect
  :  ?ping_interval:Time_ns.Span.t
  -> ?initial_backoff:Time_ns.Span.t
  -> ?max_backoff:Time_ns.Span.t
  -> ?on_reconnect:(unit -> unit)
  -> ?on_raw:(string -> unit)
  -> ?on_frame:(string -> Ws_message.t Or_error.t -> unit)
  -> ?authenticate:(unit -> Ws_request.t)
  -> ?auth_timeout:Time_ns.Span.t
  -> ?time_source:Time_source.t
  -> log_name:string
  -> Uri.t
  -> t Or_error.t Deferred.t

val messages : t -> Ws_message.t Pipe.Reader.t
(** Records the topic and sends it if the current connection is ready (authenticated
    and replayed); otherwise the replay on (re)connection sends it. Idempotent. *)
val subscribe : t -> Topic.t -> unit Deferred.t
val unsubscribe : t -> Topic.t -> unit Deferred.t

(** Unsubscribe and subscribe again, e.g. to get a fresh orderbook snapshot. *)
val resubscribe : t -> Topic.t -> unit Deferred.t

val subscriptions : t -> Topic.t list
val send : t -> Ws_request.t -> unit Deferred.t
val is_connected : t -> bool
val reconnects : t -> int
val close : t -> unit Deferred.t
val decode : string -> Ws_message.t Or_error.t
val encode : Ws_request.t -> string
