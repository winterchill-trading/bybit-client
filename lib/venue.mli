(** {!Mm_core.Venue.S} over Bybit's v5 API ([category=linear]) or the [bybit-sim]
    simulator, converted to [exchange-core] types.

    - [connect] needs [Config.api_key] (and [api_secret] for the real API). It opens the
      public and the private stream; the private one authenticates and subscribes to
      [order], [execution], [position] and [wallet]. [on_reconnect] hooks run after a
      reconnection of either stream.
    - Books: [orderbook.50.<symbol>] merged by {!Local_book}; a gap in update ids
      resubscribes for a fresh snapshot. A new reader first gets the current book, if any.
    - Ids: Bybit's string order and execution ids are mapped by {!Id_map}: decimal ids
      (the simulator's) map to the same number, others (UUIDs) to negative numbers kept in
      a table for the lifetime of [t].
    - Fills: from the [execution] topic, executions of type [Trade], [AdlTrade] and
      [BustTrade] only (not funding), de-duplicated by [execId]. The topic sends no
      snapshot, so fills before [connect] are never delivered. [closed_pnl] is [None]
      (Bybit reports it per order, not per fill).
    - Order updates: from the [order] topic. An order cancelled by the venue with nothing
      filled and a reject reason (post-only crossing, IOC with no liquidity, self-match)
      is [Rejected].
    - [place]: one [create] for a single order, [create-batch] (up to 20 per request) for
      more; [Alo] is [PostOnly], market orders are Bybit market orders ([slippage_bps] is
      ignored). Bybit only acknowledges orders, so the outcome is read back from
      [GET /v5/order/realtime] (open orders of the symbol, then by id for the rest):
      [Resting], [Filled] (anything filled) or [Rejected]. An order not visible yet counts
      as [Resting]. A non-zero [retCode] on an order is [Rejected] with the mapped reason.
    - [cancel]: one [cancel] per id; orders already gone (110001) are not an error.
    - [account]: wallet balance ([UNIFIED]) and positions ([settleCoin=USDT]).
      [realized_pnl] is Bybit's [cumRealisedPnl] (after fees and funding), [cum_funding]
      is zero, [max_leverage] comes from instruments fetched by [instrument] (else the
      position's leverage); [time] is the local clock. *)

open! Core
open! Async
open Bybit_protocol
include Mm_core.Venue.S with type config = Config.t

(** Pure conversions from Bybit's wire types, exposed for testing. *)
module Convert : sig
  val ns_of_ms : int -> int
  val fill : Id_map.t -> Execution.t -> Mm_core.Fill.t
  val is_fill : Execution.t -> bool
  val open_order : Id_map.t -> Realtime_order.t -> Exchange_core.Open_order.t
  val order_update : Id_map.t -> Realtime_order.t -> Mm_core.Order_update.t

  (** The outcome of a placed order, from its current state. *)
  val order_status : Id_map.t -> Realtime_order.t -> Exchange_core.Order_status.t

  val reject_reason : Rest.Api_error.t -> Exchange_core.Reject_reason.t

  val order_params
    :  Exchange_core.Order_request.t
    -> (Create_order.Params.t, Exchange_core.Reject_reason.t) Result.t

  val account
    :  api_key:string
    -> max_leverage:(Symbol.t -> int option)
    -> time:int
    -> Wallet_balance.t
    -> Position.t list
    -> Exchange_core.Account_view.t
end
