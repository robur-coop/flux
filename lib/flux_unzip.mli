type t

type entry = private {
    filepath: string
  ; mtime: Ptime.t
  ; meth: [ `Stored | `Deflated ]
  ; crc32: Checkseum.Crc32.t
  ; csz: int64
  ; usz: int64
  ; offset: int64
}

val of_filename : string -> (t, [> `Msg of string ]) result
val entries : t -> entry list
val stream : t -> entry -> string Flux.stream
