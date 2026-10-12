(** A live {!Market_data.Feed.t} over Bybit's public linear stream. Read-only, no
    credentials.

    Each requested stream gets its own {!Public_ws} connection, so every frame is known to
    belong to one stream before it is parsed:

    - [Trades]: [publicTrade.<symbol>], one {!Market_data.Trade.t} per print, [exch_ts]
      the fill time [T].
    - [Bbo]: [orderbook.1.<symbol>] kept in a {!Local_book}; a {!Market_data.Bbo.t} after
      every applied push while both sides are present, [exch_ts] the push [ts].
    - [L2]: [orderbook.<l2_depth>.<symbol>] (default depth 50); snapshots and deltas are
      passed through as {!Market_data.L2_update.t} once {!Local_book} accepts them (a
      snapshot's levels are sorted best first). A sequence gap resubscribes the topic,
      which makes the server send a new snapshot.
    - [Funding]: [tickers.<symbol>], deltas merged into the last snapshot; a
      {!Market_data.Funding.t} whenever the funding rate, next funding time, mark or index
      price changes, [exch_ts] the push [ts].

    [recv_ts] is [Time_ns.now ()] when the frame is received. [on_raw] gets that frame
    unparsed, first, including acks and pongs. Undecodable frames are logged and skipped.

    Disconnects are handled by {!Public_ws}: it reconnects with exponential backoff and
    resubscribes, and Bybit answers each subscription with a fresh snapshot, which is
    emitted as usual. Pipes of streams that were not requested stay empty until [close].
    Writes do not wait for readers, so consumers should keep up. *)

open! Core
open Async
open Bybit_protocol

(** Counters of one stream's connection, since {!connect}. *)
module Stats : sig
  type t =
    { frames : int (** text frames received, acks and pongs included *)
    ; parse_errors : int (** frames that did not decode or normalize; skipped *)
    ; reconnects : int (** successful reconnections of the stream's socket *)
    }
  [@@deriving sexp_of]
end

type t

(** Raises if a first connection fails, or if [streams] contains [Private].

    [time_source] (default the wall clock) stamps [recv_ts] and drives the sockets'
    keepalive, watchdog and reconnect backoff. *)
val connect
  :  ?on_raw:(stream:Market_data.Stream.t -> recv_ts:Time_ns.t -> string -> unit)
  -> ?l2_depth:int
  -> ?time_source:Time_source.t
  -> Config.t
  -> symbols:string list
  -> streams:Market_data.Stream.t list
  -> t Deferred.t

val feed : t -> Market_data.Feed.t

(** One entry per requested stream, in {!Market_data.Stream.compare} order. *)
val stats : t -> (Market_data.Stream.t * Stats.t) list

(** [connect] then [feed]. *)
val create
  :  ?on_raw:(stream:Market_data.Stream.t -> recv_ts:Time_ns.t -> string -> unit)
  -> ?l2_depth:int
  -> Config.t
  -> symbols:string list
  -> streams:Market_data.Stream.t list
  -> Market_data.Feed.t Deferred.t

(** The topics subscribed for a stream and symbol. *)
val topic : ?l2_depth:int -> Market_data.Stream.t -> Symbol.t -> Topic.t

(** Venue messages to normalized events, with the per-topic state this needs (local books,
    merged tickers). Pure apart from logging; used by {!create} and in tests. *)
module Normalizer : sig
  type t

  val create : unit -> t

  module Output : sig
    type t =
      { events : Market_data.Event.t list
      ; resubscribe : Topic.t list (** topics whose local book hit a gap *)
      }
    [@@deriving sexp_of]

    val empty : t
  end

  val message : t -> recv_ts:Time_ns.t -> Ws_message.t -> Output.t

  (** Decodes then {!message}. [Error] for a frame that is not a known message. *)
  val frame : t -> recv_ts:Time_ns.t -> string -> Output.t Or_error.t
end
