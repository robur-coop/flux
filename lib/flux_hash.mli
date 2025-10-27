val of_module : (module Digestif.S with type t = 't) -> (string, 't) Flux.sink
val md5 : (string, Digestif.MD5.t) Flux.sink
val sha1 : (string, Digestif.SHA1.t) Flux.sink
val sha224 : (string, Digestif.SHA224.t) Flux.sink
val sha256 : (string, Digestif.SHA256.t) Flux.sink
val sha384 : (string, Digestif.SHA384.t) Flux.sink
val sha512 : (string, Digestif.SHA512.t) Flux.sink
val blake2b : (string, Digestif.BLAKE2B.t) Flux.sink
val blake2s : (string, Digestif.BLAKE2S.t) Flux.sink
val whirlpool : (string, Digestif.WHIRLPOOL.t) Flux.sink
val rmd160 : (string, Digestif.RMD160.t) Flux.sink
val keccak256 : (string, Digestif.KECCAK_256.t) Flux.sink
