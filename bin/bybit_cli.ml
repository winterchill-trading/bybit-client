(* Command-line smoke tests for bybit-client, e.g. against the simulator:

   bybit-cli orderbook BTCUSDT bybit-cli tickers -testnet bybit-cli watch -orderbook
   BTCUSDT -trades BTCUSDT BYBIT_API_KEY=mm bybit-cli watch -private bybit-cli feed
   -symbol BTCUSDT -streams trades,bbo *)

open! Core
open Async
open Bybit_protocol
open Bybit_client

let config_param =
  let%map_open.Command base_url =
    flag
      "base-url"
      (optional string)
      ~doc:"URL REST root (default http://localhost:3400, the simulator)"
  and testnet = flag "testnet" no_arg ~doc:" use Bybit testnet"
  and mainnet = flag "mainnet" no_arg ~doc:" use Bybit mainnet"
  and debug = flag "debug" no_arg ~doc:" log at debug level" in
  if debug then Log.Global.set_level `Debug;
  (* Credentials come from the environment, never from the command line. *)
  let api_key = Sys.getenv "BYBIT_API_KEY" in
  let api_secret = Sys.getenv "BYBIT_API_SECRET" in
  match testnet, mainnet, base_url with
  | true, _, _ -> Config.testnet ?api_key ?api_secret ()
  | _, true, _ -> Config.mainnet ?api_key ?api_secret ()
  | false, false, Some base_url ->
    Config.create ?api_key ?api_secret ~base_url:(Uri.of_string base_url) ()
  | false, false, None -> Config.local ?api_key ?api_secret ()
;;

let print_result sexp_of = function
  | Ok value ->
    print_s (sexp_of value);
    return ()
  | Error error ->
    Print.eprint_s [%sexp (error : Error.t)];
    exit 1
;;

let orderbook_command =
  Command.async
    ~summary:"Print an orderbook snapshot from /v5/market/orderbook"
    (let%map_open.Command config = config_param
     and symbol = anon ("SYMBOL" %: string)
     and limit = flag "limit" (optional int) ~doc:"N levels per side (default 50)" in
     fun () ->
       Rest.orderbook ?limit config (Symbol.of_string symbol)
       >>= print_result [%sexp_of: Orderbook.t])
;;

let tickers_command =
  Command.async
    ~summary:"Print tickers from /v5/market/tickers"
    (let%map_open.Command config = config_param
     and symbol = anon (maybe ("SYMBOL" %: string)) in
     fun () ->
       Rest.tickers ?symbol:(Option.map symbol ~f:Symbol.of_string) config
       >>= print_result [%sexp_of: Tickers.Ticker.t list])
;;

let watch_command =
  Command.async
    ~summary:"Subscribe over the websockets and print every message"
    (let%map_open.Command config = config_param
     and orderbook =
       flag "orderbook" (listed string) ~doc:"SYMBOL subscribe to orderbook.50.SYMBOL"
     and trades = flag "trades" (listed string) ~doc:"SYMBOL subscribe to publicTrade"
     and tickers = flag "tickers" (listed string) ~doc:"SYMBOL subscribe to tickers"
     and private_ =
       flag
         "private"
         no_arg
         ~doc:" subscribe to order, execution, position and wallet (needs BYBIT_API_KEY)"
     in
     fun () ->
       let topics =
         List.concat
           [ List.map orderbook ~f:(fun s ->
               Topic.Orderbook { depth = 50; symbol = Symbol.of_string s })
           ; List.map trades ~f:(fun s -> Topic.Public_trade (Symbol.of_string s))
           ; List.map tickers ~f:(fun s -> Topic.Tickers (Symbol.of_string s))
           ]
       in
       if List.is_empty topics && not private_
       then (
         Print.eprintf "nothing to watch; pass at least one subscription flag\n";
         exit 2)
       else (
         let print message = print_s [%sexp (message : Ws_message.t)] in
         let on_reconnect () = Print.eprintf "reconnected\n" in
         let%bind public =
           if List.is_empty topics
           then return None
           else (
             let%bind ws = Public_ws.connect ~on_reconnect config >>| ok_exn in
             let%map () =
               Deferred.List.iter topics ~how:`Sequential ~f:(Public_ws.subscribe ws)
             in
             Some (Public_ws.messages ws))
         in
         let%bind private_ =
           if not private_
           then return None
           else (
             let%map ws = Private_ws.connect ~on_reconnect config >>| ok_exn in
             Some (Private_ws.messages ws))
         in
         List.filter_opt [ public; private_ ]
         |> Deferred.List.iter ~how:`Parallel ~f:(fun messages ->
           Pipe.iter_without_pushback messages ~f:print)))
;;

let feed_command =
  Command.async
    ~summary:
      "Print normalized market data (Market_data.Event.t sexps) from the public stream"
    (let%map_open.Command config = config_param
     and symbols =
       flag
         "symbol"
         (one_or_more_as_list string)
         ~doc:"SYMBOL instrument, e.g. BTCUSDT (repeat or comma-separate for several)"
     and streams =
       flag
         "streams"
         (optional_with_default
            [ Market_data.Stream.Trades; Bbo ]
            (Arg_type.comma_separated
               ~allow_empty:false
               (Arg_type.create Market_data.Stream.of_string)))
         ~doc:"LIST trades, bbo, l2, funding (default trades,bbo)"
     and l2_depth =
       flag "depth" (optional int) ~doc:"N orderbook depth for l2 (default 50)"
     and count = flag "count" (optional int) ~doc:"N exit after N events" in
     fun () ->
       let symbols = List.concat_map symbols ~f:(String.split ~on:',') in
       let%bind feed = Live_feed.create ?l2_depth config ~symbols ~streams in
       let module Feed = (val feed : Market_data.Feed.S) in
       let printed = ref 0 in
       let done_ = Ivar.create () in
       let print (event : Market_data.Event.t) =
         if Ivar.is_empty done_
         then (
           print_s [%sexp (event : Market_data.Event.t)];
           incr printed;
           match count with
           | Some count when !printed >= count -> Ivar.fill_if_empty done_ ()
           | _ -> ())
       in
       let iter pipe ~f = Pipe.iter_without_pushback pipe ~f:(fun x -> print (f x)) in
       don't_wait_for
         (let%map () =
            Deferred.all_unit
              [ iter Feed.trades ~f:(fun x -> Market_data.Event.Trade x)
              ; iter Feed.bbo ~f:(fun x -> Market_data.Event.Bbo x)
              ; iter Feed.l2 ~f:(fun x -> Market_data.Event.L2 x)
              ; iter Feed.funding ~f:(fun x -> Market_data.Event.Funding x)
              ]
          in
          Ivar.fill_if_empty done_ ());
       let%bind () = Ivar.read done_ in
       Feed.close ())
;;

let () =
  Command.group
    ~summary:"Bybit v5 API client (category linear)"
    [ "orderbook", orderbook_command
    ; "tickers", tickers_command
    ; "watch", watch_command
    ; "feed", feed_command
    ]
  |> Command_unix.run
;;
