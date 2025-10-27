open Digestif

let of_module : type t.
    (module Digestif.S with type t = t) -> (string, t) Flux.sink =
 fun (module Hash) ->
  let init () = Hash.empty
  and push ctx str = Hash.feed_string ctx str
  and full = Fun.const false
  and stop = Hash.get in
  Flux.Sink { init; push; full; stop }

let md5 = of_module (module MD5)
let sha1 = of_module (module SHA1)
let sha224 = of_module (module SHA224)
let sha256 = of_module (module SHA256)
let sha384 = of_module (module SHA384)
let sha512 = of_module (module SHA512)
let blake2b = of_module (module BLAKE2B)
let blake2s = of_module (module BLAKE2S)
let whirlpool = of_module (module WHIRLPOOL)
let rmd160 = of_module (module RMD160)
let keccak256 = of_module (module KECCAK_256)
