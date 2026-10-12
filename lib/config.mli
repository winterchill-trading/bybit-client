(** Where to reach a Bybit v5 compatible API, and the credentials to use. *)

open! Core

type t =
  { base_url : Uri.t (** REST root; [/v5/...] paths are resolved against it *)
  ; ws_public_url : Uri.t
  (** public stream, e.g. [wss://stream.bybit.com/v5/public/linear] *)
  ; ws_private_url : Uri.t (** private stream, e.g. [wss://stream.bybit.com/v5/private] *)
  ; api_key : string option (** the account; needed for private endpoints and streams *)
  ; api_secret : string option
  (** HMAC key for [X-BAPI-SIGN] and the websocket auth. Without it requests go out
      unsigned, which only the simulator accepts. *)
  ; recv_window : int (** [X-BAPI-RECV-WINDOW], ms *)
  }

(** Prints the secret as [<redacted>]. *)
val sexp_of_t : t -> Sexp.t

(** [create ~base_url ()] derives the websocket URLs from [base_url] unless given: the
    scheme [http]/[https] becomes [ws]/[wss] and the paths become [/v5/public/linear] and
    [/v5/private]. [recv_window] defaults to 5000. *)
val create
  :  ?ws_public_url:Uri.t
  -> ?ws_private_url:Uri.t
  -> ?api_key:string
  -> ?api_secret:string
  -> ?recv_window:int
  -> base_url:Uri.t
  -> unit
  -> t

(** The local simulator, [http://localhost:3400] (or [port]). *)
val local : ?port:int -> ?api_key:string -> ?api_secret:string -> unit -> t

(** [https://api.bybit.com], [wss://stream.bybit.com]. *)
val mainnet : ?api_key:string -> ?api_secret:string -> unit -> t

(** [https://api-testnet.bybit.com], [wss://stream-testnet.bybit.com]. *)
val testnet : ?api_key:string -> ?api_secret:string -> unit -> t

(** [uri t ~path ~query] is [base_url] with [path] and the already encoded [query]. *)
val uri : t -> path:string -> query:string -> Uri.t

val ws_url_of_base_url : Uri.t -> path:string -> Uri.t
