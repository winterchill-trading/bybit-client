open! Core

type t =
  { base_url : Uri.t
  ; ws_public_url : Uri.t
  ; ws_private_url : Uri.t
  ; api_key : string option
  ; api_secret : string option
  ; recv_window : int
  }

let sexp_of_t
  { base_url; ws_public_url; ws_private_url; api_key; api_secret; recv_window }
  =
  let uri u = Uri.to_string u in
  [%sexp
    { base_url : string = uri base_url
    ; ws_public_url : string = uri ws_public_url
    ; ws_private_url : string = uri ws_private_url
    ; api_key : string option
    ; api_secret : string option = Option.map api_secret ~f:(fun _ -> "<redacted>")
    ; recv_window : int
    }]
;;

let ws_url_of_base_url base_url ~path =
  let scheme =
    match Uri.scheme base_url with
    | Some "https" | Some "wss" -> "wss"
    | _ -> "ws"
  in
  Uri.make ~scheme ?host:(Uri.host base_url) ?port:(Uri.port base_url) ~path ()
;;

let create
  ?ws_public_url
  ?ws_private_url
  ?api_key
  ?api_secret
  ?(recv_window = 5000)
  ~base_url
  ()
  =
  { base_url
  ; ws_public_url =
      Option.value_or_thunk ws_public_url ~default:(fun () ->
        ws_url_of_base_url base_url ~path:"/v5/public/linear")
  ; ws_private_url =
      Option.value_or_thunk ws_private_url ~default:(fun () ->
        ws_url_of_base_url base_url ~path:"/v5/private")
  ; api_key
  ; api_secret
  ; recv_window
  }
;;

let local ?(port = 3400) ?api_key ?api_secret () =
  create
    ?api_key
    ?api_secret
    ~base_url:(Uri.of_string (sprintf "http://localhost:%d" port))
    ()
;;

let remote ~rest ~stream ?api_key ?api_secret () =
  create
    ~ws_public_url:(Uri.of_string (stream ^ "/v5/public/linear"))
    ~ws_private_url:(Uri.of_string (stream ^ "/v5/private"))
    ?api_key
    ?api_secret
    ~base_url:(Uri.of_string rest)
    ()
;;

let mainnet = remote ~rest:"https://api.bybit.com" ~stream:"wss://stream.bybit.com"

let testnet =
  remote ~rest:"https://api-testnet.bybit.com" ~stream:"wss://stream-testnet.bybit.com"
;;

let uri t ~path ~query =
  let base = Uri.to_string t.base_url |> String.chop_suffix_if_exists ~suffix:"/" in
  Uri.of_string (if String.is_empty query then base ^ path else base ^ path ^ "?" ^ query)
;;

type config = t

module Read_only = struct
  type t =
    { base_url : Uri.t
    ; ws_public_url : Uri.t
    }

  let sexp_of_t { base_url; ws_public_url } =
    [%sexp
      { base_url : string = Uri.to_string base_url
      ; ws_public_url : string = Uri.to_string ws_public_url
      }]
  ;;

  let base_url t = t.base_url
  let ws_public_url t = t.ws_public_url

  let create ?ws_public_url ~base_url () =
    let ws_public_url =
      Option.value_or_thunk ws_public_url ~default:(fun () ->
        ws_url_of_base_url base_url ~path:"/v5/public/linear")
    in
    { base_url; ws_public_url }
  ;;

  let of_config ({ base_url; ws_public_url; _ } : config) = { base_url; ws_public_url }
  let local ?port () = of_config (local ?port ())
  let mainnet () = of_config (mainnet ())
  let testnet () = of_config (testnet ())
end

let read_only = Read_only.of_config
