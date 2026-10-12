open! Core
open Async
open Bybit_protocol

type t = Ws_stream.t

let all_topics : Topic.t list = [ Order None; Execution None; Position None; Wallet ]

let auth_request (config : Config.t) ~api_key ~expires =
  match config.api_secret with
  | Some secret -> Ws_request.auth ~api_key ~secret ~expires ()
  | None -> Auth { req_id = None; api_key; expires; signature = "unsigned" }
;;

let connect
  ?ping_interval
  ?initial_backoff
  ?max_backoff
  ?on_reconnect
  ?(subscribe = all_topics)
  (config : Config.t)
  =
  match config.api_key with
  | None -> Deferred.Or_error.error_string "Private_ws.connect: the config has no API key"
  | Some api_key ->
    let authenticate () =
      let expires =
        (Time_ns.to_int_ns_since_epoch (Time_ns.now ()) / 1_000_000) + 10_000
      in
      auth_request config ~api_key ~expires
    in
    let%bind.Deferred.Or_error t =
      Ws_stream.connect
        ?ping_interval
        ?initial_backoff
        ?max_backoff
        ?on_reconnect
        ~authenticate
        ~log_name:"bybit-client private ws"
        config.ws_private_url
    in
    let%map () =
      Deferred.List.iter ~how:`Sequential subscribe ~f:(Ws_stream.subscribe t)
    in
    Ok t
;;

let messages = Ws_stream.messages
let subscribe = Ws_stream.subscribe
let unsubscribe = Ws_stream.unsubscribe
let subscriptions = Ws_stream.subscriptions
let is_connected = Ws_stream.is_connected
let close = Ws_stream.close
