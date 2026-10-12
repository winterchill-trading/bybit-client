open! Core
open! Async
open Bybit_protocol
module Neutral = Exchange_core
module Fill = Mm_core.Fill
module Neutral_update = Mm_core.Order_update

module Convert = struct
  let ns_of_ms ms = ms * 1_000_000
  let ms ts = Timestamp_ms.to_int_ms ts

  let is_fill (e : Execution.t) =
    match e.exec_type with
    | Trade | Adl_trade | Bust_trade -> true
    | Funding | Delivery | Settle | Block_trade | Move_position | Unknown | Other _ ->
      false
  ;;

  let fill ids (e : Execution.t) : Fill.t =
    { trade_id = Id_map.trade_id ids e.exec_id
    ; order_id = Id_map.order_id ids e.order_id
    ; client_order_id = e.order_link_id
    ; symbol = e.symbol
    ; side = e.side
    ; px = e.exec_price
    ; size = e.exec_qty
    ; fee = e.exec_fee
    ; is_maker = e.is_maker
    ; time = ns_of_ms (ms e.exec_time)
    ; closed_pnl = None
    }
  ;;

  let remaining (o : Realtime_order.t) =
    match o.leaves_qty with
    | Some leaves -> leaves
    | None -> Size.(max zero (o.qty - o.cum_exec_qty))
  ;;

  let open_order ids (o : Realtime_order.t) : Neutral.Open_order.t =
    { symbol = o.symbol
    ; side = o.side
    ; px = o.price
    ; size = remaining o
    ; orig_size = Some o.qty
    ; order_id = Id_map.order_id ids o.order_id
    ; client_order_id = o.order_link_id
    ; timestamp = ns_of_ms (ms o.created_time)
    }
  ;;

  (* Cancelled by the venue before anything filled, with a reason: it never rested. *)
  let never_rested (o : Realtime_order.t) =
    Size.is_zero o.cum_exec_qty
    &&
    match o.reject_reason with
    | No_error -> false
    | _ -> true
  ;;

  let update_status (o : Realtime_order.t) : Neutral_update.Status.t =
    match o.order_status with
    | New | Untriggered | Triggered -> New
    | Partially_filled -> Partially_filled
    | Filled -> Filled
    | Rejected -> Rejected
    | Cancelled | Partially_filled_canceled | Deactivated ->
      if never_rested o then Rejected else Cancelled
  ;;

  let order_update ids (o : Realtime_order.t) : Neutral_update.t =
    let status = update_status o in
    { order_id = Id_map.order_id ids o.order_id
    ; client_order_id = o.order_link_id
    ; symbol = o.symbol
    ; side = o.side
    ; px = o.price
    ; status
    ; filled = o.cum_exec_qty
    ; remaining =
        (if Neutral_update.Status.is_final status then Size.zero else remaining o)
    ; time = ns_of_ms (ms o.updated_time)
    }
  ;;

  let order_status ids (o : Realtime_order.t) : Neutral.Order_status.t =
    let order_id = Id_map.order_id ids o.order_id in
    if Order_status.is_open o.order_status
    then Resting { order_id; client_order_id = o.order_link_id }
    else if Size.is_positive o.cum_exec_qty
    then
      Filled
        { order_id
        ; total = o.cum_exec_qty
        ; avg_px = Option.value o.avg_price ~default:o.price
        ; client_order_id = o.order_link_id
        }
    else
      Rejected
        (match Reject_reason.to_exchange_core o.reject_reason with
         | Some reason -> reason
         | None -> Unsupported (Order_status.to_wire o.order_status))
  ;;

  let reject_reason ({ error; ret_code; ret_msg; path = _ } : Rest.Api_error.t)
    : Neutral.Reject_reason.t
    =
    match error with
    | Duplicate_order_link_id -> Duplicate_client_order_id
    | Wallet_balance_insufficient | Available_balance_insufficient -> Insufficient_margin
    | Qty_truncated_to_zero -> Reduce_only_would_increase
    | Price_out_of_range -> Invalid_price
    | Order_not_exists -> Order_not_found
    | _ -> Unsupported (sprintf "%d %s" ret_code ret_msg)
  ;;

  let order_params (r : Neutral.Order_request.t)
    : (Create_order.Params.t, Neutral.Reject_reason.t) Result.t
    =
    let open Result.Let_syntax in
    let%bind order_link_id =
      match r.client_order_id with
      | None -> Ok None
      | Some id ->
        (match Order_link_id.create (Neutral.Client_order_id.to_string id) with
         | Ok id -> Ok (Some id)
         | Error _ ->
           Error
             (Neutral.Reject_reason.Unsupported
                "client order id: at most 36 characters from [A-Za-z0-9_-]"))
    in
    let reduce_only = Option.some_if r.reduce_only true in
    match r.order_type, r.px with
    | Market _, _ ->
      Ok
        { Create_order.Params.symbol = r.symbol
        ; side = r.side
        ; order_type = Market
        ; qty = r.size
        ; price = None
        ; time_in_force = None
        ; reduce_only
        ; order_link_id
        ; position_idx = None
        }
    | Limit _, None -> Error Neutral.Reject_reason.Invalid_price
    | Limit tif, Some price ->
      Ok
        { symbol = r.symbol
        ; side = r.side
        ; order_type = Limit
        ; qty = r.size
        ; price = Some price
        ; time_in_force = Some (Time_in_force.of_exchange_core tif)
        ; reduce_only
        ; order_link_id
        ; position_idx = None
        }
  ;;

  let leverage_int d = Int.max 1 (Decimal.to_units d / Decimal.units_per_one)

  let position ~max_leverage (p : Position.t) : Neutral.Position_view.t =
    let size = Position.signed_size p in
    let notional =
      match p.position_value with
      | Some value -> Usd.abs value
      | None -> Mm_core.Fx.notional p.mark_price (Size.abs size)
    in
    let leverage = Option.value_map p.leverage ~default:1 ~f:leverage_int in
    { symbol = p.symbol
    ; size
    ; entry_px = p.avg_price
    ; notional
    ; unrealized_pnl = p.unrealised_pnl
    ; realized_pnl = p.cum_realised_pnl
    ; cum_funding = Usd.zero
    ; liquidation_px = p.liq_price
    ; leverage
    ; max_leverage = Option.value (max_leverage p.symbol) ~default:leverage
    ; margin_used = Usd.div_int notional leverage
    }
  ;;

  let account ~api_key ~max_leverage ~time (wallet : Wallet_balance.t) positions
    : Neutral.Account_view.t
    =
    let positions =
      List.filter positions ~f:(fun (p : Position.t) -> not (Size.is_zero p.size))
      |> List.map ~f:(position ~max_leverage)
      |> List.sort ~compare:(fun (a : Neutral.Position_view.t) b ->
        Symbol.compare a.symbol b.symbol)
    in
    let sum f = Usd.sum (List.map positions ~f) in
    let total_notional = sum (fun p -> p.notional) in
    let margin_from_positions = sum (fun p -> p.margin_used) in
    let account = Neutral.Account.of_string api_key in
    match wallet.list with
    | [] ->
      { account
      ; balance = Usd.zero
      ; equity = Usd.zero
      ; total_notional
      ; margin_used = margin_from_positions
      ; maintenance_margin = Usd.zero
      ; available = Usd.zero
      ; positions
      ; time
      }
    | w :: _ ->
      { account
      ; balance = w.total_wallet_balance
      ; equity = w.total_equity
      ; total_notional
      ; margin_used = Option.value w.total_initial_margin ~default:margin_from_positions
      ; maintenance_margin = Option.value w.total_maintenance_margin ~default:Usd.zero
      ; available = w.total_available_balance
      ; positions
      ; time
      }
  ;;
end

type config = Config.t

module Book_feed = struct
  type t =
    { book : Local_book.t
    ; mutable writers : Neutral.L2.t Pipe.Writer.t list
    }
end

type t =
  { config : Config.t
  ; api_key : string
  ; public : Public_ws.t
  ; private_ : Private_ws.t
  ; ids : Id_map.t
  ; seen_exec_ids : Exec_id.Hash_set.t
  ; fills_r : Fill.t Pipe.Reader.t
  ; fills_w : Fill.t Pipe.Writer.t
  ; updates_r : Neutral_update.t Pipe.Reader.t
  ; updates_w : Neutral_update.t Pipe.Writer.t
  ; feeds : Book_feed.t Symbol.Table.t
  ; instruments : Neutral.Instrument.t Symbol.Table.t
  ; reconnect_hooks : (unit -> unit) Queue.t
  ; mutable closed : bool
  }

let book_depth = 50

let on_public t (message : Ws_message.t) =
  match message with
  | Orderbook push ->
    (match Hashtbl.find t.feeds push.data.s with
     | None -> ()
     | Some feed ->
       (match Local_book.apply feed.book push with
        | Applied ->
          feed.writers <- List.filter feed.writers ~f:(fun w -> not (Pipe.is_closed w));
          Option.iter (Local_book.to_l2 feed.book) ~f:(fun l2 ->
            List.iter feed.writers ~f:(fun w -> Pipe.write_without_pushback w l2))
        | Stale | Waiting_for_snapshot -> ()
        | Gap { expected; received } ->
          Log.Global.info_s
            [%message
              "orderbook gap, resubscribing"
                ~symbol:(push.data.s : Symbol.t)
                (expected : int)
                (received : int)];
          don't_wait_for (Public_ws.resubscribe t.public push.topic)))
  | _ -> ()
;;

let on_private t (message : Ws_message.t) =
  match message with
  | Execution { data; _ } ->
    List.iter data ~f:(fun (e : Execution.t) ->
      if Convert.is_fill e && not (Hash_set.mem t.seen_exec_ids e.exec_id)
      then (
        Hash_set.add t.seen_exec_ids e.exec_id;
        Pipe.write_without_pushback_if_open t.fills_w (Convert.fill t.ids e)))
  | Order { data; _ } ->
    List.iter data ~f:(fun o ->
      Pipe.write_without_pushback_if_open t.updates_w (Convert.order_update t.ids o))
  | _ -> ()
;;

let connect (config : config) =
  match config.api_key with
  | None -> Deferred.Or_error.error_string "Bybit_client.Venue.connect: no API key"
  | Some api_key ->
    let open Deferred.Or_error.Let_syntax in
    let reconnect_hooks = Queue.create () in
    let on_reconnect () = Queue.iter reconnect_hooks ~f:(fun f -> f ()) in
    let%bind private_ = Private_ws.connect ~on_reconnect config in
    let%bind public =
      match%bind.Deferred Public_ws.connect ~on_reconnect (Config.read_only config) with
      | Ok public -> return public
      | Error _ as error ->
        let%bind.Deferred () = Private_ws.close private_ in
        Deferred.return error
    in
    let fills_r, fills_w = Pipe.create () in
    let updates_r, updates_w = Pipe.create () in
    let t =
      { config
      ; api_key
      ; public
      ; private_
      ; ids = Id_map.create ()
      ; seen_exec_ids = Exec_id.Hash_set.create ()
      ; fills_r
      ; fills_w
      ; updates_r
      ; updates_w
      ; feeds = Symbol.Table.create ()
      ; instruments = Symbol.Table.create ()
      ; reconnect_hooks
      ; closed = false
      }
    in
    don't_wait_for
      (Pipe.iter_without_pushback (Private_ws.messages private_) ~f:(on_private t));
    don't_wait_for
      (Pipe.iter_without_pushback (Public_ws.messages public) ~f:(on_public t));
    return t
;;

let instrument t symbol =
  match Hashtbl.find t.instruments symbol with
  | Some instrument -> Deferred.Or_error.return instrument
  | None ->
    let%map instruments = Rest.instruments_info ~symbol t.config in
    let%bind.Or_error instruments in
    (match
       List.find instruments ~f:(fun (i : Instruments_info.Instrument.t) ->
         Symbol.equal i.symbol symbol)
     with
     | None -> Or_error.error_s [%message "unknown symbol" (symbol : Symbol.t)]
     | Some instrument ->
       let instrument = Instruments_info.Instrument.to_exchange_core instrument in
       Hashtbl.set t.instruments ~key:symbol ~data:instrument;
       Ok instrument)
;;

let books t symbol =
  let r, w = Pipe.create () in
  match Hashtbl.find t.feeds symbol with
  | Some feed ->
    Option.iter (Local_book.to_l2 feed.book) ~f:(Pipe.write_without_pushback w);
    feed.writers <- w :: feed.writers;
    return r
  | None ->
    Hashtbl.set
      t.feeds
      ~key:symbol
      ~data:{ book = Local_book.create symbol; writers = [ w ] };
    let%map () =
      Public_ws.subscribe t.public (Orderbook { depth = book_depth; symbol })
    in
    r
;;

let fills t = t.fills_r
let order_updates t = t.updates_r

let open_orders t symbol =
  let%map.Deferred.Or_error orders = Rest.realtime_orders ~symbol t.config in
  List.filter_map orders ~f:(fun (o : Realtime_order.t) ->
    Option.some_if
      (Symbol.equal o.symbol symbol && Order_status.is_open o.order_status)
      (Convert.open_order t.ids o))
;;

let account t =
  let%map wallet = Rest.wallet_balance t.config
  and positions = Rest.positions t.config in
  let%map.Or_error wallet and positions in
  Convert.account
    ~api_key:t.api_key
    ~max_leverage:(fun symbol ->
      Hashtbl.find t.instruments symbol
      |> Option.map ~f:(fun (i : Neutral.Instrument.t) -> i.max_leverage))
    ~time:(Time_ns.to_int_ns_since_epoch (Time_ns.now ()))
    wallet
    positions
;;

(* An acknowledged order's id, or why it was refused. *)
type sent =
  | Acked of Order_id.t
  | Refused of Neutral.Reject_reason.t

let send_one t params =
  match%map Rest.create_order t.config params with
  | Ok (ack : Order_ack.t) -> Ok [ Acked ack.order_id ]
  | Error error ->
    (match Rest.Api_error.of_error error with
     | Some api_error -> Ok [ Refused (Convert.reject_reason api_error) ]
     | None -> Error error)
;;

let send_batch t params =
  let%map.Deferred.Or_error results = Rest.create_batch t.config params in
  List.map results ~f:(function
    | Ok (item : Create_batch.Item.t) -> Acked item.order_id
    | Error { error; ret_msg } ->
      Refused
        (Convert.reject_reason
           { path = "/v5/order/create-batch"
           ; ret_code = Envelope.Error.to_code error
           ; error
           ; ret_msg
           }))
;;

let max_batch = 20

let send t params =
  match params with
  | [] -> Deferred.Or_error.return []
  | [ one ] -> send_one t one
  | params ->
    Deferred.Or_error.List.concat_map
      ~how:`Sequential
      (List.chunks_of params ~length:max_batch)
      ~f:(fun chunk ->
        let%map.Deferred.Or_error sent = send_batch t chunk in
        if List.length sent <> List.length chunk
        then
          (* The response lists fewer items than requested: pad with rejections. *)
          sent
          @ List.init
              (List.length chunk - List.length sent)
              ~f:(fun _ -> Refused (Unsupported "missing from create-batch response"))
        else sent)
;;

(* Reads back the state of acknowledged orders: open orders of each symbol in one request,
   the rest by id. *)
let resolve t (acked : (Symbol.t * Order_id.t) list) =
  let symbols = List.dedup_and_sort (List.map acked ~f:fst) ~compare:Symbol.compare in
  let%bind open_by_symbol =
    Deferred.List.map ~how:`Parallel symbols ~f:(fun symbol ->
      match%map Rest.realtime_orders ~symbol t.config with
      | Ok orders -> orders
      | Error error ->
        Log.Global.info_s [%message "place: open orders lookup failed" (error : Error.t)];
        [])
  in
  let known = Order_id.Table.create () in
  List.iter (List.concat open_by_symbol) ~f:(fun (o : Realtime_order.t) ->
    Hashtbl.set known ~key:o.order_id ~data:o);
  let%map () =
    Deferred.List.iter ~how:`Parallel acked ~f:(fun (symbol, order_id) ->
      if Hashtbl.mem known order_id
      then return ()
      else (
        match%map Rest.realtime_orders ~symbol ~order_id t.config with
        | Ok orders ->
          List.iter orders ~f:(fun (o : Realtime_order.t) ->
            if Order_id.equal o.order_id order_id
            then Hashtbl.set known ~key:order_id ~data:o)
        | Error error ->
          Log.Global.info_s [%message "place: order lookup failed" (error : Error.t)]))
  in
  known
;;

let place t (requests : Neutral.Order_request.t list) =
  let converted = List.map requests ~f:Convert.order_params in
  let to_send = List.filter_map converted ~f:Result.ok in
  let%bind.Deferred.Or_error sent = send t to_send in
  let sent = List.zip_exn to_send sent in
  let acked =
    List.filter_map sent ~f:(fun ((params : Create_order.Params.t), s) ->
      match s with
      | Acked id -> Some (params.symbol, id)
      | Refused _ -> None)
  in
  let%map known = resolve t acked in
  let status ((params : Create_order.Params.t), s) : Neutral.Order_status.t =
    match s with
    | Refused reason -> Rejected reason
    | Acked order_id ->
      (match Hashtbl.find known order_id with
       | Some o -> Convert.order_status t.ids o
       | None ->
         Resting
           { order_id = Id_map.order_id t.ids order_id
           ; client_order_id = params.order_link_id
           })
  in
  (* Merge the local rejections back in request order. *)
  let rec merge converted sent =
    match converted, sent with
    | [], _ -> []
    | Error reason :: rest, sent ->
      Neutral.Order_status.Rejected reason :: merge rest sent
    | Ok _ :: rest, s :: sent -> status s :: merge rest sent
    | Ok _ :: _, [] -> assert false
  in
  Ok (merge converted sent)
;;

let cancel t symbol order_ids =
  let%map results =
    Deferred.List.map ~how:`Parallel order_ids ~f:(fun id ->
      match Id_map.to_bybit_order_id t.ids id with
      | None ->
        Log.Global.debug_s [%message "cancel: unknown order id" (id : Neutral.Order_id.t)];
        Deferred.Or_error.ok_unit
      | Some order_id ->
        (match%map Rest.cancel_order ~order_id t.config ~symbol with
         | Ok _ -> Ok ()
         | Error error ->
           (match Rest.Api_error.of_error error with
            | Some api_error ->
              (* Typically 110001: already filled or cancelled. *)
              Log.Global.debug_s
                [%message "cancel refused" (api_error : Rest.Api_error.t)];
              Ok ()
            | None -> Error error)))
  in
  Or_error.combine_errors_unit results
;;

let cancel_all t symbol = Rest.cancel_all t.config ~symbol |> Deferred.Or_error.ignore_m
let on_reconnect t ~f = Queue.enqueue t.reconnect_hooks f

let close t =
  if t.closed
  then return ()
  else (
    t.closed <- true;
    let%map () = Public_ws.close t.public
    and () = Private_ws.close t.private_ in
    Pipe.close t.fills_w;
    Pipe.close t.updates_w;
    Hashtbl.iter t.feeds ~f:(fun feed -> List.iter feed.writers ~f:Pipe.close))
;;
