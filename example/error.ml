let only_error = String.starts_with ~prefix:"[error]"

let () =
  Miou_unix.run @@ fun () ->
  let from = Flux.Source.file ~filename:"data.log" 0x7ff in
  let split_on_newline = Flux.Flow.split_on_char '\n' in
  let filter_on_error = Flux.Flow.filter only_error in
  let add_newline = Flux.Flow.map (fun x -> x ^ "\n") in
  let via = Flux.Flow.(split_on_newline << filter_on_error << add_newline) in
  let into = Flux.Sink.file ~filename:"error.log" in
  let (), leftover = Flux.Stream.run ~from ~via ~into in
  Option.iter Flux.Source.dispose leftover
