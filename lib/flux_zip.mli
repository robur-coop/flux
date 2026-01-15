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
(** [of_filepath filepath src] makes a new {!type:entry} from a file whose
    content is consumable via [src] (you can use {!val:Flux.Source.file}). *)

val zip : (entry, string) Flux.flow
(** [zip] It converts entries into a byte stream corresponding to the ZIP64
    format. *)
