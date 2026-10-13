open! Core
open Async

type t =
  { tcp : (Socket.Address.Inet.t, int) Tcp.Server.t
  ; block : string
  ; per_write : int
  ; greeting : string
  ; mutable writer : Writer.t option
  ; mutable ready : unit Ivar.t
  }

(* An unmasked, final text frame (server to client) holding [payload]. *)
let encode_frame payload =
  let len = String.length payload in
  let header =
    if len < 126
    then String.of_char_list [ Char.of_int_exn 0x81; Char.of_int_exn len ]
    else if len < 65536
    then
      String.of_char_list
        [ Char.of_int_exn 0x81
        ; Char.of_int_exn 126
        ; Char.of_int_exn (len lsr 8)
        ; Char.of_int_exn (len land 0xff)
        ]
    else failwith "Blast_server: frame too long"
  in
  header ^ payload
;;

let rec read_headers reader acc =
  match%bind Reader.read_line reader with
  | `Eof | `Ok "" -> return acc
  | `Ok line ->
    read_headers
      reader
      (match String.lsplit2 line ~on:':' with
       | Some (k, v) -> (String.lowercase k, String.strip v) :: acc
       | None -> acc)
;;

let handle t reader writer =
  let%bind headers = read_headers reader [] in
  let key = List.Assoc.find_exn headers ~equal:String.equal "sec-websocket-key" in
  Writer.write
    writer
    (sprintf
       "HTTP/1.1 101 Switching Protocols\r\n\
        Upgrade: websocket\r\n\
        Connection: Upgrade\r\n\
        Sec-WebSocket-Accept: %s\r\n\
        \r\n\
        %s"
       (Websocket.sec_websocket_accept_header_value ~sec_websocket_key:key)
       t.greeting);
  let ws = Websocket.create ~opcode:`Text ~role:Server reader writer in
  (* Keep an unfilled ivar that [ready] may already be waiting on. *)
  if Ivar.is_full t.ready then t.ready <- Ivar.create ();
  let ready = t.ready in
  t.writer <- Some writer;
  let from_client, (_ : string Pipe.Writer.t) = Websocket.pipes ws in
  Pipe.iter_without_pushback from_client ~f:(fun (_ : string) ->
    Ivar.fill_if_empty ready ())
;;

let start ?(greeting = []) ~frame ~per_write () =
  let block = String.concat (List.init per_write ~f:(fun _ -> encode_frame frame)) in
  let t_ref = ref None in
  let%map tcp =
    Tcp.Server.create
      ~on_handler_error:`Ignore
      Tcp.Where_to_listen.of_port_chosen_by_os
      (fun _ reader writer -> handle (Option.value_exn !t_ref) reader writer)
  in
  let greeting = String.concat (List.map greeting ~f:encode_frame) in
  let t = { tcp; block; per_write; greeting; writer = None; ready = Ivar.create () } in
  t_ref := Some t;
  t
;;

let port t = Tcp.Server.listening_on t.tcp
let ready t = Ivar.read t.ready

let blast t ~n =
  let writer = Option.value_exn t.writer ~message:"Blast_server.blast: no connection" in
  let%map () =
    Deferred.repeat_until_finished n (fun left ->
      if left <= 0
      then return (`Finished ())
      else (
        Writer.write writer t.block;
        let%map () = Writer.flushed writer in
        `Repeat (left - t.per_write)))
  in
  (n + t.per_write - 1) / t.per_write * t.per_write
;;

let close t = Tcp.Server.close ~close_existing_connections:true t.tcp
