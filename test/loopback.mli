(** A websocket server on 127.0.0.1 standing in for Bybit's public stream: tests push
    frames to connected clients and drop their sockets. *)

open! Core
open Async

type t

val start : unit -> t Deferred.t

(** A config whose public stream is this server. *)
val config : t -> Bybit_client.Config.t

(** Upgrades accepted so far. *)
val connections : t -> int

(** Text frames received from clients, oldest first. *)
val received : t -> string list

(** Sends [frame] on the most recent connection. *)
val push : t -> string -> unit

(** Closes every open client socket; clients then reconnect. *)
val drop : t -> unit Deferred.t

val close : t -> unit Deferred.t

(** Polls [f] in real time until it holds (or [timeout], default 5s). *)
val wait_until : ?timeout:Time_ns.Span.t -> (unit -> bool) -> bool Deferred.t
