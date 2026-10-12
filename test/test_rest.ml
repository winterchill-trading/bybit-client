open! Core
open Bybit_client

let config ?api_secret () =
  Config.create
    ~api_key:"XXXXXXXXXX"
    ?api_secret
    ~base_url:(Uri.of_string "https://api-testnet.bybit.com")
    ()
;;

let print_headers config ~payload =
  Rest.auth_headers config ~timestamp:1658384314791 ~payload
  |> [%sexp_of: (string * string) list Or_error.t]
  |> print_s
;;

let%expect_test "config" =
  print_s [%sexp (config ~api_secret:"secret" () : Config.t)];
  [%expect
    {|
    ((base_url https://api-testnet.bybit.com)
     (ws_public_url wss://api-testnet.bybit.com/v5/public/linear)
     (ws_private_url wss://api-testnet.bybit.com/v5/private)
     (api_key (XXXXXXXXXX)) (api_secret (<redacted>)) (recv_window 5000))
    |}];
  print_s [%sexp (Config.local () : Config.t)];
  [%expect
    {|
    ((base_url http://localhost:3400)
     (ws_public_url ws://localhost:3400/v5/public/linear)
     (ws_private_url ws://localhost:3400/v5/private) (api_key ()) (api_secret ())
     (recv_window 5000))
    |}];
  print_endline (Uri.to_string (Config.testnet ()).ws_private_url);
  [%expect {| wss://stream-testnet.bybit.com/v5/private |}]
;;

let%expect_test "query strings are sent and signed as built" =
  print_endline
    (Rest.query_string [ "category", "linear"; "symbol", "BTCUSDT"; "x", "a b&c" ]);
  [%expect {| category=linear&symbol=BTCUSDT&x=a%20b%26c |}];
  let uri = Config.uri (config ()) ~path:"/v5/order/realtime" ~query:"category=linear" in
  print_endline (Uri.to_string uri);
  [%expect {| https://api-testnet.bybit.com/v5/order/realtime?category=linear |}]
;;

let%expect_test "signed headers" =
  (* timestamp ^ api_key ^ recv_window ^ payload *)
  print_headers
    (config ~api_secret:"XXXXXXXXXX" ())
    ~payload:"category=option&symbol=BTC-29JUL22-25000-C";
  [%expect
    {|
    (Ok
     ((X-BAPI-API-KEY XXXXXXXXXX) (X-BAPI-TIMESTAMP 1658384314791)
      (X-BAPI-RECV-WINDOW 5000)
      (X-BAPI-SIGN
       c00720f96c5934ca7057ac28ae65b823f83b8b67a8fe784e7795ca0fa3c148ec)))
    |}];
  let expected =
    Bybit_protocol.Signature.sign
      ~secret:"XXXXXXXXXX"
      ~timestamp:1658384314791
      ~api_key:"XXXXXXXXXX"
      ~recv_window:5000
      ~payload:"category=option&symbol=BTC-29JUL22-25000-C"
  in
  print_endline expected;
  [%expect {| c00720f96c5934ca7057ac28ae65b823f83b8b67a8fe784e7795ca0fa3c148ec |}];
  (* Without a secret (simulator), no signature header. *)
  print_headers (config ()) ~payload:"";
  [%expect
    {|
    (Ok
     ((X-BAPI-API-KEY XXXXXXXXXX) (X-BAPI-TIMESTAMP 1658384314791)
      (X-BAPI-RECV-WINDOW 5000)))
    |}];
  print_headers (Config.local ()) ~payload:"";
  [%expect {| (Error "Bybit_client: private request without an API key") |}]
;;

let decode body =
  Rest.decode ~status:200 ~body ~result_of_yojson:Bybit_protocol.Order_ack.t_of_yojson
;;

let%expect_test "envelopes" =
  print_s
    [%sexp
      (decode
         {|{"retCode":0,"retMsg":"OK","result":{"orderId":"1","orderLinkId":""},"retExtInfo":{},"time":1}|}
       : (Bybit_protocol.Order_ack.t * Bybit_protocol.Json.t) Or_error.t)];
  [%expect {| (Ok (((order_id 1) (order_link_id ())) {})) |}];
  let error =
    decode
      {|{"retCode":110001,"retMsg":"order not exists or too late to cancel","result":{},"retExtInfo":{},"time":1}|}
  in
  print_s [%sexp (Result.is_error error : bool)];
  [%expect {| true |}];
  (match error with
   | Ok _ -> ()
   | Error error ->
     print_s [%sexp (Rest.Api_error.of_error error : Rest.Api_error.t option)]);
  [%expect
    {|
    (((path "") (ret_code 110001) (error Order_not_exists)
      (ret_msg "order not exists or too late to cancel")))
    |}];
  (match decode "<html>rate limited</html>" with
   | Ok _ -> ()
   | Error error ->
     print_s [%sexp (Rest.Api_error.of_error error : Rest.Api_error.t option)];
     print_s [%sexp (error : Error.t)]);
  [%expect
    {|
    ()
    ("not JSON" (status 200) (body "<html>rate limited</html>"))
    |}]
;;
