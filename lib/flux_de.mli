type cfg

val config :
  ?level:int -> ?size_of_queue:int -> ?size_of_window:int -> unit -> cfg

val deflate : cfg:cfg -> (Bstr.t, string) Flux.flow
