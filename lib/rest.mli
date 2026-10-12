(** Bybit v5 REST: public GETs, signed private GETs and POSTs, and the response envelope.

    Every call returns [_ Or_error.t Deferred.t]. Transport failures, bodies that are not
    an envelope, a non-zero [retCode] and decoding failures of [result] become [Error]; a
    [retCode] error carries the code, its {!Bybit_protocol.Envelope.Error.t} and [retMsg].

    Private requests carry [X-BAPI-API-KEY], [X-BAPI-TIMESTAMP] (now, in ms),
    [X-BAPI-RECV-WINDOW] and [X-BAPI-SIGN] = HMAC-SHA256 of
    [timestamp ^ api_key ^ recv_window ^ payload], where [payload] is the query string for
    GET and the JSON body for POST, byte for byte as sent. Without [Config.api_secret] the
    signature header is omitted (the simulator does not check it). *)

open! Core
open Async
open Bybit_protocol

(** A non-zero [retCode]. Such errors carry the structured value inside the [Error.t], so
    callers can tell a venue rejection from a transport failure. *)
module Api_error : sig
  type t =
    { path : string (** the endpoint, [""] from {!decode} *)
    ; ret_code : int
    ; error : Envelope.Error.t
    ; ret_msg : string
    }
  [@@deriving sexp_of]

  (** [Some] when [error] is a venue rejection. *)
  val of_error : Error.t -> t option
end

(** {2 Transport} *)

(** [key=value&...] in the given order, values percent-encoded as query values. This exact
    string is both sent and signed. *)
val query_string : (string * string) list -> string

(** The [X-BAPI-*] headers for a private request. [Error] without [Config.api_key]. *)
val auth_headers
  :  Config.t
  -> timestamp:int
  -> payload:string
  -> (string * string) list Or_error.t

(** Decodes an envelope (any HTTP status) into [result] and [retExtInfo]. *)
val decode
  :  status:int
  -> body:string
  -> result_of_yojson:(Yojson.Safe.t -> 'a)
  -> ('a * Yojson.Safe.t) Or_error.t

val get_public
  :  Config.t
  -> path:string
  -> query:(string * string) list
  -> result_of_yojson:(Yojson.Safe.t -> 'a)
  -> 'a Or_error.t Deferred.t

val get_private
  :  Config.t
  -> path:string
  -> query:(string * string) list
  -> result_of_yojson:(Yojson.Safe.t -> 'a)
  -> 'a Or_error.t Deferred.t

(** Returns [result] and [retExtInfo]. *)
val post_private
  :  Config.t
  -> path:string
  -> body:Yojson.Safe.t
  -> result_of_yojson:(Yojson.Safe.t -> 'a)
  -> ('a * Yojson.Safe.t) Or_error.t Deferred.t

(** {2 Market (public)} *)

(** [GET /v5/market/instruments-info]. *)
val instruments_info
  :  ?symbol:Symbol.t
  -> Config.t
  -> Instruments_info.Instrument.t list Or_error.t Deferred.t

(** [GET /v5/market/orderbook]; [limit] defaults to 50. *)
val orderbook : ?limit:int -> Config.t -> Symbol.t -> Orderbook.t Or_error.t Deferred.t

(** [GET /v5/market/tickers]. *)
val tickers : ?symbol:Symbol.t -> Config.t -> Tickers.Ticker.t list Or_error.t Deferred.t

(** {2 Trading (private)}

    Create, cancel and amend return an acknowledgement only; the outcome arrives on the
    [order] topic or through {!realtime_orders}. *)

val create_order : Config.t -> Create_order.Params.t -> Order_ack.t Or_error.t Deferred.t

(** [POST /v5/order/create-batch]: one result per request, in order. An item whose
    [retExtInfo] status is non-zero is [Error] with that code and message. *)
val create_batch
  :  Config.t
  -> Create_order.Params.t list
  -> (Create_batch.Item.t, Envelope.error) Result.t list Or_error.t Deferred.t

val cancel_order
  :  ?order_id:Order_id.t
  -> ?order_link_id:Order_link_id.t
  -> Config.t
  -> symbol:Symbol.t
  -> Order_ack.t Or_error.t Deferred.t

(** Cancels every order on [symbol]. *)
val cancel_all : Config.t -> symbol:Symbol.t -> Order_ack.t list Or_error.t Deferred.t

val amend_order
  :  ?order_id:Order_id.t
  -> ?order_link_id:Order_link_id.t
  -> ?qty:Size.t
  -> ?price:Price.t
  -> Config.t
  -> symbol:Symbol.t
  -> Order_ack.t Or_error.t Deferred.t

(** {2 Account (private)} *)

(** [GET /v5/order/realtime]: open orders, or the given order whatever its status.
    [settle_coin] defaults to ["USDT"] when no [symbol] is given (one of them is required
    for [linear], also when looking up an id). *)
val realtime_orders
  :  ?symbol:Symbol.t
  -> ?settle_coin:string
  -> ?order_id:Order_id.t
  -> ?order_link_id:Order_link_id.t
  -> Config.t
  -> Realtime_order.t list Or_error.t Deferred.t

(** [GET /v5/execution/list], newest first. *)
val executions
  :  ?symbol:Symbol.t
  -> ?order_id:Order_id.t
  -> ?limit:int
  -> Config.t
  -> Execution.t list Or_error.t Deferred.t

(** [GET /v5/position/list]; [settle_coin] defaults to ["USDT"] when no [symbol] is given. *)
val positions
  :  ?symbol:Symbol.t
  -> ?settle_coin:string
  -> Config.t
  -> Position.t list Or_error.t Deferred.t

(** [GET /v5/account/wallet-balance]; [account_type] defaults to ["UNIFIED"]. *)
val wallet_balance
  :  ?account_type:string
  -> Config.t
  -> Wallet_balance.t Or_error.t Deferred.t
