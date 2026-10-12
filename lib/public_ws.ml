open! Core

type t = Ws_stream.t

let connect
  ?ping_interval
  ?initial_backoff
  ?max_backoff
  ?on_reconnect
  ?on_raw
  ?on_frame
  ?time_source
  (config : Config.Read_only.t)
  =
  Ws_stream.connect
    ?ping_interval
    ?initial_backoff
    ?max_backoff
    ?on_reconnect
    ?on_raw
    ?on_frame
    ?time_source
    ~log_name:"bybit-client public ws"
    (Config.Read_only.ws_public_url config)
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
