open! Core

type t = Live_feed.Normalizer.t

let venue = Market_data.Venue.Bybit
let create () = Live_feed.Normalizer.create ()

let frame t ~recv_ts payload =
  Or_error.map
    (Live_feed.Normalizer.frame t ~recv_ts payload)
    ~f:(fun (o : Live_feed.Normalizer.Output.t) -> o.events)
;;

let disconnect = Live_feed.Normalizer.reset
