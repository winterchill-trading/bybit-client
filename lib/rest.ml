open! Core
open Async
open Bybit_protocol

let category = Category.to_wire Linear

let query_string params =
  List.map params ~f:(fun (key, value) ->
    key ^ "=" ^ Uri.pct_encode ~component:`Query_value value)
  |> String.concat ~sep:"&"
;;

let now_ms () = Time_ns.to_int_ns_since_epoch (Time_ns.now ()) / 1_000_000

let auth_headers (config : Config.t) ~timestamp ~payload =
  match config.api_key with
  | None -> Or_error.error_string "Bybit_client: private request without an API key"
  | Some api_key ->
    let recv_window = config.recv_window in
    Ok
      (match config.api_secret with
       | Some secret ->
         Signature.headers ~secret ~timestamp ~api_key ~recv_window ~payload
       | None ->
         [ "X-BAPI-API-KEY", api_key
         ; "X-BAPI-TIMESTAMP", Int.to_string timestamp
         ; "X-BAPI-RECV-WINDOW", Int.to_string recv_window
         ])
;;

module Api_error = struct
  type t =
    { path : string
    ; ret_code : int
    ; error : Envelope.Error.t
    ; ret_msg : string
    }
  [@@deriving sexp_of]

  (* The registered exception printer must be portable, which [Envelope.Error.sexp_of_t]
     is not: carry the code and rebuild [error] from it. *)
  exception
    E of
      { path : string
      ; ret_code : int
      ; ret_msg : string
      }
  [@@deriving sexp_of]

  let to_exn { path; ret_code; error = _; ret_msg } = E { path; ret_code; ret_msg }

  let of_error error =
    match Error.to_exn error with
    | E { path; ret_code; ret_msg } ->
      Option.map (Envelope.Error.of_code ret_code) ~f:(fun error ->
        { path; ret_code; error; ret_msg })
    | _ -> None
  ;;
end

let decode_at ~path ~status ~body ~result_of_yojson =
  let fail error = Or_error.error_s [%message error (status : int) (body : string)] in
  match Yojson.Safe.from_string body with
  | exception _ -> fail "not JSON"
  | json ->
    (match Envelope.decode json ~result_of_yojson with
     | exception exn ->
       Or_error.error_s
         [%message "undecodable response" (status : int) (body : string) (exn : exn)]
     | Error { error; ret_msg } ->
       Error
         (Error.of_exn
            (Api_error.to_exn
               { path; ret_code = Envelope.Error.to_code error; error; ret_msg }))
     | Ok result ->
       let ext = Option.value (Json.member json ~key:"retExtInfo") ~default:(`Assoc []) in
       Ok (result, ext))
;;

let decode ~status ~body ~result_of_yojson =
  decode_at ~path:"" ~status ~body ~result_of_yojson
;;

(* Venue rejections are left untagged so that [Api_error.of_error] finds them. *)
let finish ~meth ~path ~result_of_yojson response =
  match response with
  | Error error ->
    Error (Error.tag_s error ~tag:[%message (meth : string) (path : string)])
  | Ok (status, body) ->
    (match decode_at ~path ~status ~body ~result_of_yojson with
     | Ok _ as ok -> ok
     | Error error as result ->
       (match Api_error.of_error error with
        | Some _ -> result
        | None ->
          Error (Error.tag_s error ~tag:[%message (meth : string) (path : string)])))
;;

let get_public config ~path ~query ~result_of_yojson =
  let uri = Config.uri config ~path ~query:(query_string query) in
  let%map response = Venue_net.Http.get uri in
  finish ~meth:"GET" ~path ~result_of_yojson response |> Or_error.map ~f:fst
;;

let get_private config ~path ~query ~result_of_yojson =
  let query = query_string query in
  match auth_headers config ~timestamp:(now_ms ()) ~payload:query with
  | Error _ as error -> return error
  | Ok headers ->
    let%map response = Venue_net.Http.get ~headers (Config.uri config ~path ~query) in
    finish ~meth:"GET" ~path ~result_of_yojson response |> Or_error.map ~f:fst
;;

let post_private config ~path ~body ~result_of_yojson =
  let body = Yojson.Safe.to_string body in
  match auth_headers config ~timestamp:(now_ms ()) ~payload:body with
  | Error _ as error -> return error
  | Ok headers ->
    let headers = ("Content-Type", "application/json") :: headers in
    let%map response =
      Venue_net.Http.request ~headers ~body `POST (Config.uri config ~path ~query:"")
    in
    finish ~meth:"POST" ~path ~result_of_yojson response
;;

let opt key value ~f = Option.map value ~f:(fun v -> key, f v)

let params required optional =
  ("category", category) :: (required @ List.filter_map optional ~f:Fn.id)
;;

(* Market *)

let page_list of_yojson json = (Page.t_of_yojson of_yojson json).list

let instruments_info ?symbol config =
  get_public
    config
    ~path:"/v5/market/instruments-info"
    ~query:(params [] [ opt "symbol" symbol ~f:Symbol.to_string ])
    ~result_of_yojson:(page_list Instruments_info.Instrument.t_of_yojson)
;;

let orderbook ?(limit = 50) config symbol =
  get_public
    config
    ~path:"/v5/market/orderbook"
    ~query:(params [ "symbol", Symbol.to_string symbol; "limit", Int.to_string limit ] [])
    ~result_of_yojson:Orderbook.t_of_yojson
;;

let tickers ?symbol config =
  get_public
    config
    ~path:"/v5/market/tickers"
    ~query:(params [] [ opt "symbol" symbol ~f:Symbol.to_string ])
    ~result_of_yojson:(page_list Tickers.Ticker.t_of_yojson)
;;

(* Trading *)

let post config ~path body ~result_of_yojson =
  post_private config ~path ~body ~result_of_yojson |> Deferred.Or_error.map ~f:fst
;;

let create_order config params =
  post
    config
    ~path:"/v5/order/create"
    (Create_order.Request.yojson_of_t { category = Linear; params })
    ~result_of_yojson:Order_ack.t_of_yojson
;;

let create_batch config request =
  let%map.Deferred.Or_error response, ext =
    post_private
      config
      ~path:"/v5/order/create-batch"
      ~body:(Create_batch.Request.yojson_of_t { category = Linear; request })
      ~result_of_yojson:Create_batch.Response.t_of_yojson
  in
  let statuses =
    match Create_batch.Ext_info.t_of_yojson ext with
    | ext -> ext.list
    | exception _ -> []
  in
  List.mapi response.list ~f:(fun i item ->
    match Option.bind (List.nth statuses i) ~f:Create_batch.Ext_info.Status.error with
    | None -> Ok item
    | Some error ->
      let ret_msg = (List.nth_exn statuses i).msg in
      Error { Envelope.error; ret_msg })
;;

let cancel_order ?order_id ?order_link_id config ~symbol =
  post
    config
    ~path:"/v5/order/cancel"
    (Cancel_order.Request.yojson_of_t
       { category = Linear; symbol; order_id; order_link_id })
    ~result_of_yojson:Order_ack.t_of_yojson
;;

let cancel_all config ~symbol =
  post
    config
    ~path:"/v5/order/cancel-all"
    (Cancel_all.Request.yojson_of_t
       { category = Linear
       ; symbol = Some symbol
       ; base_coin = None
       ; settle_coin = None
       ; order_filter = None
       })
    ~result_of_yojson:Cancel_all.Response.t_of_yojson
  |> Deferred.Or_error.map ~f:(fun (r : Cancel_all.Response.t) -> r.list)
;;

let amend_order ?order_id ?order_link_id ?qty ?price config ~symbol =
  post
    config
    ~path:"/v5/order/amend"
    (Amend_order.Request.yojson_of_t
       { category = Linear
       ; symbol
       ; order_id
       ; order_link_id
       ; qty
       ; price
       ; trigger_price = None
       })
    ~result_of_yojson:Order_ack.t_of_yojson
;;

(* Account *)

let realtime_orders ?symbol ?settle_coin ?order_id ?order_link_id config =
  let settle_coin =
    match symbol, settle_coin with
    | None, None -> Some "USDT"
    | _ -> settle_coin
  in
  get_private
    config
    ~path:"/v5/order/realtime"
    ~query:
      (params
         []
         [ opt "symbol" symbol ~f:Symbol.to_string
         ; opt "settleCoin" settle_coin ~f:Fn.id
         ; opt "orderId" order_id ~f:Order_id.to_string
         ; opt "orderLinkId" order_link_id ~f:Order_link_id.to_string
         ])
    ~result_of_yojson:(page_list Realtime_order.t_of_yojson)
;;

let executions ?symbol ?order_id ?limit config =
  get_private
    config
    ~path:"/v5/execution/list"
    ~query:
      (params
         []
         [ opt "symbol" symbol ~f:Symbol.to_string
         ; opt "orderId" order_id ~f:Order_id.to_string
         ; opt "limit" limit ~f:Int.to_string
         ])
    ~result_of_yojson:(page_list Execution.t_of_yojson)
;;

let positions ?symbol ?settle_coin config =
  let settle_coin =
    match symbol, settle_coin with
    | None, None -> Some "USDT"
    | _ -> settle_coin
  in
  get_private
    config
    ~path:"/v5/position/list"
    ~query:
      (params
         []
         [ opt "symbol" symbol ~f:Symbol.to_string
         ; opt "settleCoin" settle_coin ~f:Fn.id
         ])
    ~result_of_yojson:(page_list Position.t_of_yojson)
;;

let wallet_balance ?(account_type = "UNIFIED") config =
  get_private
    config
    ~path:"/v5/account/wallet-balance"
    ~query:[ "accountType", account_type ]
    ~result_of_yojson:Wallet_balance.t_of_yojson
;;
