type cfg

val config :
  ?level:int -> ?size_of_queue:int -> ?size_of_window:int -> unit -> cfg

val deflate : cfg -> (Bstr.t, string) Flux.flow
val inflate : (Bstr.t, string) Flux.flow
