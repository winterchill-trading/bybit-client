(** Bybit's private stream ([/v5/private]): the account's orders, executions, positions
    and wallet.

    On every (re)connection the client first sends
    [{"op":"auth","args":[api_key, expires, signature]}], with [expires] 10s ahead and
    [signature = HMAC-SHA256(api_secret, "GET/realtime" ^ expires)], waits for the auth
    ack, then resends every subscription. Without [Config.api_secret] the signature is the
    placeholder ["unsigned"], which only the simulator accepts.

    Keepalive, reconnection and [messages] behave as in {!Public_ws}. *)

open! Core
open Async
open Bybit_protocol

type t

(** The four private topics, uncategorised: [order], [execution], [position], [wallet]. *)
val all_topics : Topic.t list

(** Fails without [Config.api_key]. [subscribe] defaults to {!all_topics}. *)
val connect
  :  ?ping_interval:Time_ns.Span.t
  -> ?initial_backoff:Time_ns.Span.t
  -> ?max_backoff:Time_ns.Span.t
  -> ?on_reconnect:(unit -> unit)
  -> ?subscribe:Topic.t list
  -> Config.t
  -> t Or_error.t Deferred.t

val messages : t -> Ws_message.t Pipe.Reader.t
val subscribe : t -> Topic.t -> unit Deferred.t
val unsubscribe : t -> Topic.t -> unit Deferred.t
val subscriptions : t -> Topic.t list
val is_connected : t -> bool
val close : t -> unit Deferred.t

(** The [auth] request for [expires] (ms). *)
val auth_request : Config.t -> api_key:string -> expires:int -> Ws_request.t
