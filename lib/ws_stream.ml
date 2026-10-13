open! Core
open Async
open Bybit_protocol
module Ws_client = Venue_net.Ws_client

let decode frame =
  Or_error.try_with (fun () -> Ws_message.t_of_yojson (Yojson.Safe.from_string frame))
;;

let encode request = Yojson.Safe.to_string (Ws_request.yojson_of_t request)

type t =
  { client : Ws_client.t
  ; subscriptions : Topic.t list ref (** in subscription order *)
  ; messages : Ws_message.t Pipe.Reader.t
  ; ready : bool ref
  (** the current connection is authenticated (or needs no auth) and its subscriptions
      have been replayed; until then [subscribe] only records the topic *)
  }

let messages t = t.messages
let subscriptions t = !(t.subscriptions)
let is_connected t = Ws_client.is_connected t.client
let reconnects t = Ws_client.reconnects t.client
let send t request = Ws_client.send t.client (encode request)
let subscribe_request topic = Ws_request.Subscribe { req_id = None; args = [ topic ] }
let send_if_ready t request = if !(t.ready) then send t request else return ()
let mem t topic = List.mem !(t.subscriptions) topic ~equal:Topic.equal

let subscribe t topic =
  if mem t topic
  then return ()
  else (
    t.subscriptions := !(t.subscriptions) @ [ topic ];
    send_if_ready t (subscribe_request topic))
;;

let unsubscribe t topic =
  if not (mem t topic)
  then return ()
  else (
    t.subscriptions
    := List.filter !(t.subscriptions) ~f:(fun s -> not (Topic.equal s topic));
    send_if_ready t (Unsubscribe { req_id = None; args = [ topic ] }))
;;

let resubscribe t topic =
  if not (mem t topic)
  then subscribe t topic
  else (
    let%bind () = send_if_ready t (Unsubscribe { req_id = None; args = [ topic ] }) in
    send_if_ready t (subscribe_request topic))
;;

let connect
  ?(ping_interval = Time_ns.Span.of_int_sec 20)
  ?(initial_backoff = Time_ns.Span.of_ms 500.)
  ?(max_backoff = Time_ns.Span.of_int_sec 30)
  ?(on_reconnect = fun () -> ())
  ?(on_raw = fun (_ : string) -> ())
  ?(intercept = fun (_ : string) -> false)
  ?(on_frame = fun (_ : string) (_ : Ws_message.t Or_error.t) -> ())
  ?authenticate
  ?(auth_timeout = Time_ns.Span.of_int_sec 10)
  ?(time_source = Time_source.wall_clock ())
  ~log_name
  url
  =
  let subscriptions = ref [] in
  let ready = ref false in
  let auth_ack : Op_response.t Ivar.t option ref = ref None in
  let out_r, out_w = Pipe.create () in
  let on_decoded frame =
    let decoded = decode frame in
    on_frame frame decoded;
    match decoded with
    | Error error ->
      Log.Global.debug_s
        [%message (log_name ^ ": undecodable frame") (frame : string) (error : Error.t)]
    | Ok message ->
      (match message with
       | Auth_ack response ->
         Option.iter !auth_ack ~f:(fun ivar -> Ivar.fill_if_empty ivar response)
       | Subscribe_ack response when Op_response.is_failure response ->
         Log.Global.error_s
           [%message (log_name ^ ": subscription refused") (response : Op_response.t)]
       | Unknown json ->
         Log.Global.debug_s [%message (log_name ^ ": unknown message") (json : Json.t)]
       | _ -> ());
      Pipe.write_without_pushback_if_open out_w message
  in
  let on_text frame =
    on_raw frame;
    if not (intercept frame) then on_decoded frame
  in
  let authenticated client =
    match authenticate with
    | None -> return ()
    | Some request ->
      let ivar = Ivar.create () in
      auth_ack := Some ivar;
      let%bind () = Ws_client.send client (encode (request ())) in
      (match%map Time_source.with_timeout time_source auth_timeout (Ivar.read ivar) with
       | `Timeout -> Log.Global.error "%s: no auth ack" log_name
       | `Result response ->
         if Op_response.is_failure response
         then
           Log.Global.error_s
             [%message (log_name ^ ": auth failed") (response : Op_response.t)])
  in
  let on_connect client =
    ready := false;
    let%bind () = authenticated client in
    (* Read the set and mark the stream ready in the same job: a topic subscribed before
       this point is replayed here, one subscribed after is sent by [subscribe]. *)
    let topics = !subscriptions in
    ready := true;
    let%map () =
      Deferred.List.iter ~how:`Sequential topics ~f:(fun topic ->
        Ws_client.send client (encode (subscribe_request topic)))
    in
    if Ws_client.reconnects client > 0 then on_reconnect ()
  in
  let%map.Deferred.Or_error client =
    Ws_client.connect
      ~ping:(`Text (encode (Ping { req_id = None }), ping_interval))
      ~max_silent_intervals:2
      ~initial_backoff
      ~max_backoff
      ~on_connect
      ~time_source
      ~log_name
      ~url
      ()
  in
  don't_wait_for
    (let%map () = Pipe.iter_without_pushback (Ws_client.messages client) ~f:on_text in
     Pipe.close out_w);
  { client; subscriptions; messages = out_r; ready }
;;

let close t = Ws_client.close t.client
