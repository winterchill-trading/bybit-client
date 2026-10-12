(** Async client for the Bybit v5 API ([category=linear]), built on the [Bybit_protocol]
    wire types and the [Venue_net] transport. *)

(** Endpoints and credentials. *)
module Config = Config

(** Public and signed private REST endpoints. *)
module Rest = Rest

(** Public websocket stream with ping, reconnect and resubscription. *)
module Public_ws = Public_ws

(** Orderbook snapshot and delta merging with update id checks. *)
module Local_book = Local_book

(** Authenticated private websocket stream (orders, executions, positions, wallet). *)
module Private_ws = Private_ws
