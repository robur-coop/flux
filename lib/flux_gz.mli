type cfg

val config :
     ?mtime:int32
  -> ?level:int
  -> ?size_of_queue:int
  -> ?size_of_window:int
  -> ?os:Gz.os
  -> unit
  -> cfg

val deflate : cfg -> (Bstr.t, string) Flux.flow
val inflate : (Bstr.t, string) Flux.flow
