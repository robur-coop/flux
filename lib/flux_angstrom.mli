val parser : 'a Angstrom.t -> (string, ('a, string option) result) Flux.sink
(** [parser p] makes a {!type:Flux.sink} that consumes bytes to parse them
    according to [p] and return the result or an error. *)
