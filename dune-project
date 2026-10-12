(lang dune 3.17)

(name bybit-client)

(generate_opam_files true)

(license MIT)

(maintainers "winterchill-trading")

(authors "winterchill-trading")

(source
 (github winterchill-trading/bybit-client))

(package
 (name bybit-client)
 (synopsis "Async client for the Bybit v5 HTTP and websocket API")
 (depends
  (ocaml
   (>= 5.2))
  dune
  core
  core_unix
  async
  async_ssl
  venue-net
  bybit-protocol
  exchange-core
  mm-core
  cryptokit
  ppx_jane
  ppx_yojson_conv
  yojson
  uri
  (bybit-sim :with-test)
  (exchange-core-engine :with-test)))
