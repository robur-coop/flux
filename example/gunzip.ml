let () =
  Miou_unix.run @@ fun () ->
  let via = Flux.Flow.(bstr ~len:0x7ff << Flux_gz.inflate) in
  let from = Flux.Source.in_channel stdin in
  let into = Flux.Sink.out_channel stdout in
  let (), leftover = Flux.Stream.run ~from ~via ~into in
  Option.iter Flux.Source.dispose leftover
