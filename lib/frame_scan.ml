open! Core

module Kind = struct
  type t =
    | Trades
    | Book
  [@@deriving sexp_of, equal]
end

type t =
  { mutable pos : int (** cursor *)
  ; mutable str_pos : int (** last string read *)
  ; mutable str_len : int
  ; mutable kind : Kind.t
  ; mutable topic_pos : int
  ; mutable topic_len : int
  ; mutable snapshot : bool
  ; mutable ts : int
  ; mutable symbol_pos : int
  ; mutable symbol_len : int
  ; mutable update_id : int
  ; capacity : int
  ; mutable bids : int
  ; bid_price : int array
  ; bid_size : int array
  ; mutable asks : int
  ; ask_price : int array
  ; ask_size : int array
  ; mutable trades : int
  ; trade_time : int array
  ; trade_price : int array
  ; trade_size : int array
  ; trade_buy : bool array
  ; trade_symbol_pos : int array
  ; trade_symbol_len : int array
  ; trade_id_pos : int array
  ; trade_id_len : int array
  }

let create ?(capacity = 1024) () =
  let ints () = Array.create ~len:capacity 0 in
  { pos = 0
  ; str_pos = 0
  ; str_len = 0
  ; kind = Book
  ; topic_pos = 0
  ; topic_len = 0
  ; snapshot = false
  ; ts = 0
  ; symbol_pos = 0
  ; symbol_len = 0
  ; update_id = 0
  ; capacity
  ; bids = 0
  ; bid_price = ints ()
  ; bid_size = ints ()
  ; asks = 0
  ; ask_price = ints ()
  ; ask_size = ints ()
  ; trades = 0
  ; trade_time = ints ()
  ; trade_price = ints ()
  ; trade_size = ints ()
  ; trade_buy = Array.create ~len:capacity false
  ; trade_symbol_pos = ints ()
  ; trade_symbol_len = ints ()
  ; trade_id_pos = ints ()
  ; trade_id_len = ints ()
  }
;;

exception Fail

let[@zero_alloc] fail () = raise_notrace Fail

let[@zero_alloc] equal_sub s ~pos ~len lit =
  if len <> String.length lit || pos < 0 || pos + len > String.length s
  then false
  else (
    let mutable i = 0 in
    while
      i < len && Char.equal (String.unsafe_get s (pos + i)) (String.unsafe_get lit i)
    do
      i <- i + 1
    done;
    i = len)
;;

let[@zero_alloc] [@inline] is_digit c = Char.( >= ) c '0' && Char.( <= ) c '9'

let[@zero_alloc] [@inline] is_space c =
  Char.equal c ' ' || Char.equal c '\n' || Char.equal c '\r' || Char.equal c '\t'
;;

let[@zero_alloc] [@inline] ws t s =
  let n = String.length s in
  let mutable i = t.pos in
  while i < n && is_space (String.unsafe_get s i) do
    i <- i + 1
  done;
  t.pos <- i
;;

(* The next character after whitespace, not consumed. *)
let[@zero_alloc] [@inline] peek t s =
  ws t s;
  if t.pos >= String.length s then fail ();
  String.unsafe_get s t.pos
;;

let[@zero_alloc] [@inline] expect t s c =
  if not (Char.equal (peek t s) c) then fail ();
  t.pos <- t.pos + 1
;;

(* A string without escapes; its contents go to [str_pos] and [str_len]. *)
let[@zero_alloc] string t s =
  expect t s '"';
  let n = String.length s in
  let start = t.pos in
  let mutable i = start in
  while i < n && not (Char.equal (String.unsafe_get s i) '"') do
    if Char.equal (String.unsafe_get s i) '\\' then fail ();
    i <- i + 1
  done;
  if i >= n then fail ();
  t.str_pos <- start;
  t.str_len <- i - start;
  t.pos <- i + 1
;;

(* A non-negative JSON integer of at most 18 digits. *)
let[@zero_alloc] int t s =
  ws t s;
  let n = String.length s in
  let start = t.pos in
  let mutable i = start in
  let mutable v = 0 in
  while i < n && is_digit (String.unsafe_get s i) do
    v <- (v * 10) + (Char.to_int (String.unsafe_get s i) - 48);
    i <- i + 1
  done;
  if i = start || i - start > 18 then fail ();
  t.pos <- i;
  v
;;

let decimals = 8

(* A quoted non-negative decimal, ["123"] or ["123.45"], with at most 10 integer digits
   (well inside the {!Fixed_decimal} range), in units of 10^-8; further fractional digits
   are truncated, as [Fixed_decimal.of_string] does. *)
let[@zero_alloc] decimal t s =
  expect t s '"';
  let n = String.length s in
  let start = t.pos in
  let mutable i = start in
  let mutable v = 0 in
  while i < n && is_digit (String.unsafe_get s i) do
    v <- (v * 10) + (Char.to_int (String.unsafe_get s i) - 48);
    i <- i + 1
  done;
  if i = start || i - start > 10 || i >= n then fail ();
  let mutable frac = 0 in
  if Char.equal (String.unsafe_get s i) '.'
  then (
    i <- i + 1;
    let frac_start = i in
    while i < n && is_digit (String.unsafe_get s i) do
      if frac < decimals
      then (
        v <- (v * 10) + (Char.to_int (String.unsafe_get s i) - 48);
        frac <- frac + 1);
      i <- i + 1
    done;
    if i = frac_start then fail ());
  if i >= n || not (Char.equal (String.unsafe_get s i) '"') then fail ();
  while frac < decimals do
    v <- v * 10;
    frac <- frac + 1
  done;
  t.pos <- i + 1;
  v
;;

(* Any JSON value, not validated beyond bracket and string nesting. *)
let[@zero_alloc] skip_value t s =
  let n = String.length s in
  ignore (peek t s : char);
  let mutable i = t.pos in
  let mutable depth = 0 in
  let mutable fin = false in
  while not fin do
    if i >= n then fail ();
    let c = String.unsafe_get s i in
    if Char.equal c '"'
    then (
      i <- i + 1;
      while i < n && not (Char.equal (String.unsafe_get s i) '"') do
        if Char.equal (String.unsafe_get s i) '\\' then i <- i + 2 else i <- i + 1
      done;
      if i >= n then fail ();
      i <- i + 1;
      if depth = 0 then fin <- true)
    else if Char.equal c '{' || Char.equal c '['
    then (
      depth <- depth + 1;
      i <- i + 1)
    else if Char.equal c '}' || Char.equal c ']'
    then (
      if depth = 0 then fail ();
      depth <- depth - 1;
      i <- i + 1;
      if depth = 0 then fin <- true)
    else if depth > 0
    then i <- i + 1
    else (
      (* a scalar: up to the next delimiter *)
      while
        i < n
        && (not (is_space (String.unsafe_get s i)))
        && not
             (Char.equal (String.unsafe_get s i) ','
              || Char.equal (String.unsafe_get s i) '}'
              || Char.equal (String.unsafe_get s i) ']')
      do
        i <- i + 1
      done;
      fin <- true)
  done;
  t.pos <- i
;;

(* After a member: [true] if another one follows, [false] at the closing [close]. *)
let[@zero_alloc] [@inline] more t s close =
  let c = peek t s in
  t.pos <- t.pos + 1;
  if Char.equal c ',' then true else if Char.equal c close then false else fail ()
;;

(* An object key and its colon; the key is in [str_pos], [str_len]. *)
let[@zero_alloc] [@inline] key t s =
  string t s;
  expect t s ':'
;;

let[@zero_alloc] [@inline] is_key t s lit = equal_sub s ~pos:t.str_pos ~len:t.str_len lit

let[@zero_alloc] levels t s ~(price : int array) ~(size : int array) =
  expect t s '[';
  let mutable count = 0 in
  if Char.equal (peek t s) ']'
  then t.pos <- t.pos + 1
  else (
    let mutable continue = true in
    while continue do
      if count >= t.capacity then fail ();
      expect t s '[';
      let p = decimal t s in
      expect t s ',';
      let q = decimal t s in
      expect t s ']';
      Array.unsafe_set price count p;
      Array.unsafe_set size count q;
      count <- count + 1;
      continue <- more t s ']'
    done);
  count
;;

let[@zero_alloc] book t s =
  expect t s '{';
  let mutable seen = 0 in
  let mutable continue = true in
  while continue do
    key t s;
    if is_key t s "s"
    then (
      string t s;
      t.symbol_pos <- t.str_pos;
      t.symbol_len <- t.str_len;
      seen <- seen lor 1)
    else if is_key t s "b"
    then (
      t.bids <- levels t s ~price:t.bid_price ~size:t.bid_size;
      seen <- seen lor 2)
    else if is_key t s "a"
    then (
      t.asks <- levels t s ~price:t.ask_price ~size:t.ask_size;
      seen <- seen lor 4)
    else if is_key t s "u"
    then (
      t.update_id <- int t s;
      seen <- seen lor 8)
    else if is_key t s "seq"
    then (
      ignore (int t s : int);
      seen <- seen lor 16)
    else skip_value t s;
    continue <- more t s '}'
  done;
  if seen <> 31 then fail ()
;;

let[@zero_alloc] trade t s i =
  expect t s '{';
  let mutable seen = 0 in
  let mutable continue = true in
  while continue do
    key t s;
    if is_key t s "T"
    then (
      Array.unsafe_set t.trade_time i (int t s);
      seen <- seen lor 1)
    else if is_key t s "s"
    then (
      string t s;
      Array.unsafe_set t.trade_symbol_pos i t.str_pos;
      Array.unsafe_set t.trade_symbol_len i t.str_len;
      seen <- seen lor 2)
    else if is_key t s "S"
    then (
      string t s;
      if is_key t s "Buy"
      then Array.unsafe_set t.trade_buy i true
      else if is_key t s "Sell"
      then Array.unsafe_set t.trade_buy i false
      else fail ();
      seen <- seen lor 4)
    else if is_key t s "v"
    then (
      Array.unsafe_set t.trade_size i (decimal t s);
      seen <- seen lor 8)
    else if is_key t s "p"
    then (
      Array.unsafe_set t.trade_price i (decimal t s);
      seen <- seen lor 16)
    else if is_key t s "i"
    then (
      string t s;
      Array.unsafe_set t.trade_id_pos i t.str_pos;
      Array.unsafe_set t.trade_id_len i t.str_len;
      seen <- seen lor 32)
    else skip_value t s;
    continue <- more t s '}'
  done;
  if seen <> 63 then fail ()
;;

let[@zero_alloc] trades t s =
  expect t s '[';
  let mutable count = 0 in
  if Char.equal (peek t s) ']'
  then t.pos <- t.pos + 1
  else (
    let mutable continue = true in
    while continue do
      if count >= t.capacity then fail ();
      trade t s count;
      count <- count + 1;
      continue <- more t s ']'
    done);
  t.trades <- count
;;

let[@zero_alloc] frame t s =
  t.pos <- 0;
  expect t s '{';
  let mutable seen = 0 in
  let mutable continue = true in
  while continue do
    key t s;
    if is_key t s "topic"
    then (
      string t s;
      t.topic_pos <- t.str_pos;
      t.topic_len <- t.str_len;
      seen <- seen lor 1)
    else if is_key t s "type"
    then (
      string t s;
      if is_key t s "snapshot"
      then t.snapshot <- true
      else if is_key t s "delta"
      then t.snapshot <- false
      else fail ();
      seen <- seen lor 2)
    else if is_key t s "ts"
    then (
      t.ts <- int t s;
      seen <- seen lor 4)
    else if is_key t s "data"
    then (
      let c = peek t s in
      if Char.equal c '{'
      then (
        t.kind <- Book;
        book t s)
      else if Char.equal c '['
      then (
        t.kind <- Trades;
        trades t s)
      else fail ();
      seen <- seen lor 8)
    else if is_key t s "op"
    then fail ()
    else skip_value t s;
    continue <- more t s '}'
  done;
  ws t s;
  if seen <> 15 || t.pos <> String.length s then fail ();
  let prefix_ok =
    match t.kind with
    | Trades -> t.topic_len > 12 && equal_sub s ~pos:t.topic_pos ~len:12 "publicTrade."
    | Book -> t.topic_len > 10 && equal_sub s ~pos:t.topic_pos ~len:10 "orderbook."
  in
  if not prefix_ok then fail ()
;;

let[@zero_alloc] scan t s =
  match frame t s with
  | () -> true
  | exception Fail -> false
;;

let kind t = t.kind
let topic_pos t = t.topic_pos
let topic_len t = t.topic_len
let snapshot t = t.snapshot
let ts t = t.ts
let symbol_pos t = t.symbol_pos
let symbol_len t = t.symbol_len
let update_id t = t.update_id
let bids t = t.bids
let asks t = t.asks
let bid_price t i = t.bid_price.(i)
let bid_size t i = t.bid_size.(i)
let ask_price t i = t.ask_price.(i)
let ask_size t i = t.ask_size.(i)
let trades t = t.trades
let trade_time t i = t.trade_time.(i)
let trade_price t i = t.trade_price.(i)
let trade_size t i = t.trade_size.(i)
let trade_buy t i = t.trade_buy.(i)
let trade_symbol_pos t i = t.trade_symbol_pos.(i)
let trade_symbol_len t i = t.trade_symbol_len.(i)
let trade_id_pos t i = t.trade_id_pos.(i)
let trade_id_len t i = t.trade_id_len.(i)
