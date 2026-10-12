(** {!Live_feed.Normalizer} as a {!Market_data.Normalizer.S}, so [rebuild-norm] can turn
    market-recorder raw files of Bybit back into events:
    [Market_data.Rebuild_norm.command [ (module Bybit_client.Raw_normalizer) ]].

    Books are kept per topic, so any [orderbook.<depth>] subscription works; a
    [disconnect] clears books and tickers as a reconnect does. Resubscriptions after a
    sequence gap are not sent (there is no connection); the book stays empty until the
    snapshot the live feed asked for shows up in the recording. *)

include Market_data.Normalizer.S with type t = Live_feed.Normalizer.t
