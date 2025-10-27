let repeat n =
  let flow (Flux.Sink k) =
    let init () = k.init () in
    let rec push acc x =
      assert (not (full acc));
      let rec go acc = function
        | 0 -> acc
        | _ when k.full acc -> acc
        | n -> go (k.push acc x) (n - 1)
      in
      go acc n
    and full acc = k.full acc in
    let stop acc = k.stop acc in
    Flux.Sink { init; push; full; stop }
  in
  { Flux.flow }

let buffer len =
  if len < 0 then invalid_arg "buffer: negative buffer size";
  let flow (Flux.Sink k) =
    let init () = (k.init (), 0)
    and push (acc, idx) x =
      if idx = len then (acc, idx) else (k.push acc x, idx + 1)
    and full (acc, idx) = k.full acc || idx = len
    and stop (acc, _) = k.stop acc in
    Flux.Sink { init; push; full; stop }
  in
  { Flux.flow }

let () =
  Miou_unix.run @@ fun () ->
  let open Flux in
  let from = Source.list [ 1; 2; 3 ] in
  let into = Sink.list in
  let via = Flow.(repeat 3 << buffer 6) in
  let lst, _ = Stream.run ~from ~via ~into in
  assert (lst = [ 1; 1; 1; 2; 2; 2 ])
