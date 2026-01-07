type entry = private {
    filepath: string
  ; mtime: Ptime.t
  ; tz_offset_s: Ptime.tz_offset_s option
  ; src: string Flux.source
  ; level: int
}

val of_filepath :
     ?tz_offset_s:Ptime.tz_offset_s
  -> ?mtime:Ptime.t
  -> ?level:int
  -> string
  -> string Flux.source
  -> entry

val zip : (entry, string) Flux.flow
