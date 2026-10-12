open! Core

type t = Ws_stream.t

let connect
  ?ping_interval
  ?initial_backoff
  ?max_backoff
  ?on_reconnect
  ?on_raw
  (config : Config.t)
  =
  Ws_stream.connect
    ?ping_interval
    ?initial_backoff
    ?max_backoff
    ?on_reconnect
    ?on_raw
    ~log_name:"bybit-client public ws"
    config.ws_public_url
;;

let messages = Ws_stream.messages
let subscribe = Ws_stream.subscribe
let unsubscribe = Ws_stream.unsubscribe
let resubscribe = Ws_stream.resubscribe
let subscriptions = Ws_stream.subscriptions
let send = Ws_stream.send
let is_connected = Ws_stream.is_connected
let reconnects = Ws_stream.reconnects
let close = Ws_stream.close

module For_testing = struct
  let decode = Ws_stream.decode
  let encode = Ws_stream.encode
end
