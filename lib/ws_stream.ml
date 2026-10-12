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
  ; ready : unit Ivar.t ref
  (** filled once the current connection is authenticated (immediately without auth) *)
  }

let messages t = t.messages
let subscriptions t = !(t.subscriptions)
let is_connected t = Ws_client.is_connected t.client
let reconnects t = Ws_client.reconnects t.client
let send t request = Ws_client.send t.client (encode request)
let subscribe_request topic = Ws_request.Subscribe { req_id = None; args = [ topic ] }

let send_when_ready t request =
  let%bind () = Ivar.read !(t.ready) in
  send t request
;;

let mem t topic = List.mem !(t.subscriptions) topic ~equal:Topic.equal

let subscribe t topic =
  if mem t topic
  then return ()
  else (
    t.subscriptions := !(t.subscriptions) @ [ topic ];
    send_when_ready t (subscribe_request topic))
;;

let unsubscribe t topic =
  if not (mem t topic)
  then return ()
  else (
    t.subscriptions
    := List.filter !(t.subscriptions) ~f:(fun s -> not (Topic.equal s topic));
    send t (Unsubscribe { req_id = None; args = [ topic ] }))
;;

let resubscribe t topic =
  if not (mem t topic)
  then subscribe t topic
  else (
    let%bind () = send_when_ready t (Unsubscribe { req_id = None; args = [ topic ] }) in
    send t (subscribe_request topic))
;;

let connect
  ?(ping_interval = Time_ns.Span.of_int_sec 20)
  ?(initial_backoff = Time_ns.Span.of_ms 500.)
  ?(max_backoff = Time_ns.Span.of_int_sec 30)
  ?(on_reconnect = fun () -> ())
  ?authenticate
  ?(auth_timeout = Time_ns.Span.of_int_sec 10)
  ~log_name
  url
  =
  let subscriptions = ref [] in
  let ready = ref (Ivar.create ()) in
  let auth_ack : Op_response.t Ivar.t option ref = ref None in
  let out_r, out_w = Pipe.create () in
  let on_frame frame =
    match decode frame with
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
  let authenticated client =
    match authenticate with
    | None -> return ()
    | Some request ->
      let ivar = Ivar.create () in
      auth_ack := Some ivar;
      let%bind () = Ws_client.send client (encode (request ())) in
      (match%map Clock_ns.with_timeout auth_timeout (Ivar.read ivar) with
       | `Timeout -> Log.Global.error "%s: no auth ack" log_name
       | `Result response ->
         if Op_response.is_failure response
         then
           Log.Global.error_s
             [%message (log_name ^ ": auth failed") (response : Op_response.t)])
  in
  let on_connect client =
    (* Senders still waiting on an earlier connection are released together with this one;
       anything they send is also covered by the replay below. *)
    let previous = !ready in
    let this_connection = Ivar.create () in
    ready := this_connection;
    let%bind () = authenticated client in
    Ivar.fill_if_empty this_connection ();
    Ivar.fill_if_empty previous ();
    let%map () =
      Deferred.List.iter ~how:`Sequential !subscriptions ~f:(fun topic ->
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
      ~log_name
      ~url
      ()
  in
  don't_wait_for
    (let%map () = Pipe.iter_without_pushback (Ws_client.messages client) ~f:on_frame in
     Pipe.close out_w);
  { client; subscriptions; messages = out_r; ready }
;;

let close t = Ws_client.close t.client
