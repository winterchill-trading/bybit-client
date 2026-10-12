# Recorded frames

Raw text frames from Bybit's public linear stream
(`wss://stream.bybit.com/v5/public/linear`), BTCUSDT, recorded without credentials on
2026-10-12 with one connection per stream, one frame per line, exactly as received:

| file            | topic                  |
| --------------- | ---------------------- |
| `trades.jsonl`  | `publicTrade.BTCUSDT`  |
| `bbo.jsonl`     | `orderbook.1.BTCUSDT`  |
| `l2.jsonl`      | `orderbook.50.BTCUSDT` |
| `funding.jsonl` | `tickers.BTCUSDT`      |

A minute was recorded and trimmed to the first 20 seconds of venue time per stream
(frames without `ts`, such as the subscription ack, are kept). `test_fixtures.ml` decodes
every frame and runs it through `Live_feed.Normalizer`.
